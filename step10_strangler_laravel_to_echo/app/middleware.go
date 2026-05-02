package main

import (
	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
)

// RequestIDMiddleware は X-Request-ID ヘッダを伝播するミドルウェア。
//
// 動作:
//  1. リクエストに X-Request-ID ヘッダがあればそれを使用する
//  2. なければ UUID v4 を新規生成する
//  3. request_id をコンテキストにセット (ハンドラから c.Get("request_id") で取得可能)
//  4. レスポンスヘッダ X-Request-ID に同じ値をセットする
//
// これにより Nginx -> Echo -> 応答 の全経路でリクエスト追跡が可能になる。
// Laravel 側の X-Request-ID とも同じ ID を共有することで、
// モノリス分解後もログを横断検索できる。
func RequestIDMiddleware() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			// 1. リクエストヘッダから取得
			reqID := c.Request().Header.Get("X-Request-ID")

			// 2. なければ新規生成
			if reqID == "" {
				reqID = uuid.New().String()
			}

			// 3. コンテキストにセット (ハンドラから参照可能)
			c.Set("request_id", reqID)

			// 4. レスポンスヘッダにセット
			c.Response().Header().Set("X-Request-ID", reqID)

			return next(c)
		}
	}
}
