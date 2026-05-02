<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;

/**
 * HeartbeatController
 *
 * Accepts device heartbeat payloads and writes them to the `heartbeats` table.
 * This is the high-volume write endpoint that students optimise in the
 * write-scaling modules (batching, async queuing, time-series partitioning).
 */
class HeartbeatController extends Controller
{
    /**
     * POST /api/heartbeat
     *
     * Expected JSON body:
     * {
     *   "device_id": "dev-acme-001",   // required, string max 100 chars
     *   "status":    "ok"              // optional, defaults to "ok"
     * }
     *
     * Returns:
     *   201 – heartbeat recorded
     *   422 – validation error
     */
    public function store(Request $request): JsonResponse
    {
        $validator = Validator::make($request->all(), [
            'device_id' => ['required', 'string', 'max:100'],
            'status'    => ['sometimes', 'string', 'max:20'],
        ]);

        if ($validator->fails()) {
            return response()->json([
                'error'  => 'Validation failed',
                'errors' => $validator->errors(),
            ], 422);
        }

        $deviceId    = $request->input('device_id');
        $status      = $request->input('status', 'ok');
        $receivedAt  = now()->format('Y-m-d H:i:s');

        DB::insert(
            'INSERT INTO heartbeats (device_id, status, received_at) VALUES (?, ?, ?)',
            [$deviceId, $status, $receivedAt]
        );

        $id = DB::getPdo()->lastInsertId();

        return response()->json([
            'data' => [
                'id'          => (int) $id,
                'device_id'   => $deviceId,
                'status'      => $status,
                'received_at' => $receivedAt,
            ],
        ], 201);
    }
}
