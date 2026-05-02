package queue

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// ── インターフェース定義 ───────────────────────────────────────────────────────

// Event はキューに流れるイベントの基本構造体
type Event struct {
	ID        string    // Redis Stream の Message ID (XADD が生成する "1700000000000-0" 形式)
	DeviceID  string    // デバイス識別子
	EventType string    // イベント種別 (heartbeat, alert, telemetry など)
	Payload   string    // JSON ペイロード (任意)
	CreatedAt time.Time // イベント発生時刻
	// 冪等性キー: 同じキーを持つイベントは1度しか処理しない
	IdempotencyKey string
}

// EventHandler はイベントを受け取って処理する関数型
// エラーを返した場合は Worker がリトライする
type EventHandler func(ctx context.Context, event Event) error

// Queue はメッセージキューの抽象インターフェース
// Redis Stream 以外 (SQS, Kafka など) への差し替えを容易にする
type Queue interface {
	// Publish はイベントをストリームに追加する (プロデューサー側)
	Publish(ctx context.Context, stream string, event Event) error

	// Subscribe はストリームを購読してイベントをハンドラに渡す (コンシューマー側)
	// group: Consumer Group 名
	// consumer: このワーカーインスタンスの名前 (複数ワーカー時に一意にする)
	// handler: イベント処理関数
	Subscribe(ctx context.Context, stream string, group string, consumer string, handler EventHandler) error

	// CreateGroup は Consumer Group を作成する (なければ作成、あればスキップ)
	CreateGroup(ctx context.Context, stream string, group string) error
}

// ── Redis Stream 実装 ─────────────────────────────────────────────────────────

// RedisStreamQueue は Redis Streams を使った Queue 実装
type RedisStreamQueue struct {
	client      *redis.Client
	readTimeout time.Duration // XREADGROUP のブロック待機時間
	maxRetries  int           // Consumer Group を作成するリトライ数
}

// NewRedisStreamQueue は RedisStreamQueue を生成する
func NewRedisStreamQueue(client *redis.Client) *RedisStreamQueue {
	return &RedisStreamQueue{
		client:      client,
		readTimeout: 5 * time.Second,
		maxRetries:  3,
	}
}

// Publish はイベントを Redis Stream に XADD する
// 冪等性キーを含む全フィールドをストリームエントリとして書き込む
func (q *RedisStreamQueue) Publish(ctx context.Context, stream string, event Event) error {
	values := map[string]interface{}{
		"device_id":       event.DeviceID,
		"event_type":      event.EventType,
		"payload":         event.Payload,
		"created_at":      event.CreatedAt.UTC().Format(time.RFC3339),
		"idempotency_key": event.IdempotencyKey,
	}

	// XADD <stream> * field1 value1 field2 value2 ...
	// "*" は Redis に ID (タイムスタンプ-シーケンス) を自動生成させる
	result, err := q.client.XAdd(ctx, &redis.XAddArgs{
		Stream: stream,
		MaxLen: 100000, // ストリームの最大長 (古いエントリを自動削除)
		Approx: true,   // 近似トリミング (パフォーマンス優先)
		Values: values,
	}).Result()
	if err != nil {
		return fmt.Errorf("XADD to stream %s failed: %w", stream, err)
	}

	// result は生成された Message ID ("1700000000000-0" 形式)
	_ = result
	return nil
}

// Subscribe はストリームを XREADGROUP でブロッキング読み取りする
// ctx がキャンセルされるまで処理を継続する
func (q *RedisStreamQueue) Subscribe(
	ctx context.Context,
	stream string,
	group string,
	consumer string,
	handler EventHandler,
) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// XREADGROUP GROUP <group> <consumer> COUNT 10 BLOCK 5000 STREAMS <stream> >
		// ">" は新しい未配信メッセージのみを読む
		streams, err := q.client.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    group,
			Consumer: consumer,
			Streams:  []string{stream, ">"},
			Count:    10,                // 1回に最大10件取得
			Block:    q.readTimeout,    // 新メッセージがなければ最大5秒待つ
			NoAck:    false,
		}).Result()

		if err != nil {
			if err == redis.Nil {
				// タイムアウト (新メッセージなし) — ループを継続
				continue
			}
			// コンテキストキャンセルは正常終了
			if ctx.Err() != nil {
				return nil
			}
			// それ以外のエラーは少し待ってリトライ
			time.Sleep(1 * time.Second)
			continue
		}

		for _, stream := range streams {
			for _, msg := range stream.Messages {
				event := messageToEvent(msg)

				// ハンドラでエラーが返った場合は NACK (XACK しない)
				// → Pending メッセージとして残り、再処理可能
				if err := handler(ctx, event); err != nil {
					// エラーログは Worker 側で行う
					// XACK しないことで pending のまま残す
					continue
				}

				// 正常処理完了 → XACK でメッセージを確認済みにする
				// XACK <stream> <group> <id>
				if ackErr := q.client.XAck(ctx, stream.Stream, group, msg.ID).Err(); ackErr != nil {
					// XACK の失敗は致命的ではない (冪等性で対応)
					// ログだけ残して続行
					_ = ackErr
				}
			}
		}
	}
}

// CreateGroup は Consumer Group を作成する
// MKSTREAM オプションでストリームが存在しない場合も自動作成
func (q *RedisStreamQueue) CreateGroup(ctx context.Context, stream string, group string) error {
	// XGROUP CREATE <stream> <group> $ MKSTREAM
	// "$" は「このグループが登録された以降の新規メッセージのみ処理」を意味する
	err := q.client.XGroupCreateMkStream(ctx, stream, group, "$").Err()
	if err != nil {
		// BUSYGROUP エラーは「グループが既に存在する」を意味するので無視
		if err.Error() == "BUSYGROUP Consumer Group name already exists" {
			return nil
		}
		return fmt.Errorf("XGROUP CREATE failed for stream=%s group=%s: %w", stream, group, err)
	}
	return nil
}

// ── ヘルパー関数 ──────────────────────────────────────────────────────────────

// messageToEvent は Redis Stream の XMessage を Event 構造体に変換する
func messageToEvent(msg redis.XMessage) Event {
	e := Event{
		ID: msg.ID,
	}

	if v, ok := msg.Values["device_id"].(string); ok {
		e.DeviceID = v
	}
	if v, ok := msg.Values["event_type"].(string); ok {
		e.EventType = v
	}
	if v, ok := msg.Values["payload"].(string); ok {
		e.Payload = v
	}
	if v, ok := msg.Values["idempotency_key"].(string); ok {
		e.IdempotencyKey = v
	}
	if v, ok := msg.Values["created_at"].(string); ok {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			e.CreatedAt = t
		}
	} else {
		e.CreatedAt = time.Now()
	}

	return e
}
