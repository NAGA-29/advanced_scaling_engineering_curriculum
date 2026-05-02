package main

import (
	"errors"
	"sync"
	"time"
)

// ── Circuit Breaker の状態 ────────────────────────────────────────────────────

// State は Circuit Breaker の状態を表す
type State int

const (
	// StateClosed: 正常状態。リクエストを通す。
	// 失敗が maxFailures に達すると StateOpen に遷移。
	StateClosed State = iota

	// StateOpen: 遮断状態。リクエストを即座に拒否する。
	// timeout 経過後に StateHalfOpen に遷移。
	StateOpen

	// StateHalfOpen: 回復テスト状態。
	// 1リクエストだけ通し、成功なら StateClosed、失敗なら StateOpen に戻る。
	StateHalfOpen
)

func (s State) String() string {
	switch s {
	case StateClosed:
		return "CLOSED"
	case StateOpen:
		return "OPEN"
	case StateHalfOpen:
		return "HALF-OPEN"
	default:
		return "UNKNOWN"
	}
}

// ── Circuit Breaker 本体 ──────────────────────────────────────────────────────

// ErrCircuitOpen は Circuit Breaker が OPEN 状態の時に返されるエラー
var ErrCircuitOpen = errors.New("circuit breaker is OPEN: request rejected")

// CircuitBreaker はシンプルな Circuit Breaker 実装
//
// 状態遷移:
//
//	CLOSED  --[maxFailures 回連続失敗]--> OPEN
//	OPEN    --[timeout 経過]-----------> HALF-OPEN
//	HALF-OPEN --[成功]-----------------> CLOSED
//	HALF-OPEN --[失敗]-----------------> OPEN
type CircuitBreaker struct {
	maxFailures  int           // 何回連続で失敗したら OPEN にするか
	timeout      time.Duration // OPEN が続く最大時間 (この後 HALF-OPEN になる)
	failures     int           // 現在の連続失敗回数
	successCount int           // HALF-OPEN 時の成功回数 (将来の拡張用)
	lastFailTime time.Time     // 最後に失敗した時刻
	state        State         // 現在の状態
	mu           sync.Mutex    // 状態変更を保護
}

// NewCircuitBreaker は CircuitBreaker を生成する
// maxFailures: 連続失敗回数の閾値
// timeout: OPEN 状態を維持する時間
func NewCircuitBreaker(maxFailures int, timeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		maxFailures: maxFailures,
		timeout:     timeout,
		state:       StateClosed,
	}
}

// Call は fn を Circuit Breaker 経由で実行する
//
// CLOSED:    fn を実行。失敗なら failures をインクリメント
// OPEN:      fn を実行せず ErrCircuitOpen を返す
// HALF-OPEN: fn を実行。成功なら CLOSED、失敗なら OPEN に戻す
func (cb *CircuitBreaker) Call(fn func() error) error {
	cb.mu.Lock()
	state := cb.currentState()
	cb.mu.Unlock()

	switch state {
	case StateOpen:
		// リクエストを拒否
		return ErrCircuitOpen

	case StateHalfOpen:
		// 1回テスト
		err := fn()
		cb.mu.Lock()
		defer cb.mu.Unlock()
		if err != nil {
			// テスト失敗 → OPEN に戻す
			cb.failures = cb.maxFailures
			cb.lastFailTime = time.Now()
			cb.state = StateOpen
			return err
		}
		// テスト成功 → CLOSED に戻す
		cb.reset()
		return nil

	default: // StateClosed
		err := fn()
		cb.mu.Lock()
		defer cb.mu.Unlock()
		if err != nil {
			cb.failures++
			cb.lastFailTime = time.Now()
			if cb.failures >= cb.maxFailures {
				cb.state = StateOpen
			}
			return err
		}
		// 成功 → 失敗カウントをリセット
		cb.reset()
		return nil
	}
}

// State は現在の外部向け状態を返す (ロック不使用; 読み取り用)
func (cb *CircuitBreaker) State() State {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.currentState()
}

// Failures は現在の連続失敗回数を返す
func (cb *CircuitBreaker) Failures() int {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.failures
}

// ── 内部メソッド (mu 保持前提) ───────────────────────────────────────────────

// currentState は現在の状態を計算する (mu を保持した状態で呼ぶこと)
func (cb *CircuitBreaker) currentState() State {
	if cb.state == StateOpen {
		// timeout 経過後は HALF-OPEN に遷移
		if time.Since(cb.lastFailTime) >= cb.timeout {
			cb.state = StateHalfOpen
			return StateHalfOpen
		}
		return StateOpen
	}
	return cb.state
}

// reset は失敗カウントをクリアして CLOSED 状態に戻す
func (cb *CircuitBreaker) reset() {
	cb.failures = 0
	cb.successCount = 0
	cb.state = StateClosed
}

// ── Circuit Breaker Stats (観測用) ───────────────────────────────────────────

// Stats は Circuit Breaker の現在の統計情報
type Stats struct {
	State        string    `json:"state"`
	Failures     int       `json:"failures"`
	MaxFailures  int       `json:"max_failures"`
	LastFailTime time.Time `json:"last_fail_time,omitempty"`
	TimeUntilRetry string  `json:"time_until_retry,omitempty"`
}

// GetStats は観測用の統計情報を返す
func (cb *CircuitBreaker) GetStats() Stats {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	state := cb.currentState()
	stats := Stats{
		State:       state.String(),
		Failures:    cb.failures,
		MaxFailures: cb.maxFailures,
	}

	if !cb.lastFailTime.IsZero() {
		stats.LastFailTime = cb.lastFailTime
	}

	if state == StateOpen {
		remaining := cb.timeout - time.Since(cb.lastFailTime)
		if remaining > 0 {
			stats.TimeUntilRetry = remaining.Round(time.Millisecond).String()
		}
	}

	return stats
}
