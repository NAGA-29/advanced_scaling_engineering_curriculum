<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\UserController;
use App\Http\Controllers\HeartbeatController;
use App\Http\Controllers\EventController;

/*
|--------------------------------------------------------------------------
| API Routes
|--------------------------------------------------------------------------
|
| These routes are loaded by the RouteServiceProvider within a group which
| is assigned the "api" middleware group. Enjoy building your API!
|
| Base URL prefix: /api  (configured in RouteServiceProvider)
|
*/

// ── Liveness / health check ──────────────────────────────────────────────────
Route::get('/health', function () {
    return response()->json(['status' => 'ok', 'service' => 'laravel-legacy']);
});

// ── Users ────────────────────────────────────────────────────────────────────
// GET  /api/users        – paginated list (used by load tests and admin UIs)
// GET  /api/users/{id}   – single user lookup by primary key
Route::get('/users',       [UserController::class, 'index']);
Route::get('/users/{id}',  [UserController::class, 'show']);

// ── Heartbeats ───────────────────────────────────────────────────────────────
// POST /api/heartbeat    – record a device heartbeat
Route::post('/heartbeat', [HeartbeatController::class, 'store']);

// ── Events ───────────────────────────────────────────────────────────────────
// POST /api/events       – append a generic event record
Route::post('/events', [EventController::class, 'store']);
