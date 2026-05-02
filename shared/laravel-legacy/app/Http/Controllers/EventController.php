<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;

/**
 * EventController
 *
 * Generic event-ingestion endpoint. Writes free-form event records so that
 * students can experiment with high-volume append-only write patterns without
 * coupling the exercise to a specific domain table.
 */
class EventController extends Controller
{
    /**
     * POST /api/events
     *
     * Expected JSON body:
     * {
     *   "type":    "page_view",          // required, string max 100 chars
     *   "payload": { ... }               // optional, arbitrary JSON object
     * }
     *
     * Returns:
     *   201 – event recorded
     *   422 – validation error
     */
    public function store(Request $request): JsonResponse
    {
        $validator = Validator::make($request->all(), [
            'type'    => ['required', 'string', 'max:100'],
            'payload' => ['sometimes', 'array'],
        ]);

        if ($validator->fails()) {
            return response()->json([
                'error'  => 'Validation failed',
                'errors' => $validator->errors(),
            ], 422);
        }

        $type       = $request->input('type');
        $payload    = $request->input('payload', []);
        $occurredAt = now()->format('Y-m-d H:i:s');

        // Use the heartbeats table as a generic event sink for simplicity —
        // the "status" column carries the event type and "device_id" carries
        // a stringified payload excerpt. In production you would have a
        // dedicated events table; this keeps the schema minimal.
        DB::insert(
            'INSERT INTO heartbeats (device_id, status, received_at) VALUES (?, ?, ?)',
            [
                'event:' . substr(json_encode($payload), 0, 93),
                $type,
                $occurredAt,
            ]
        );

        $id = DB::getPdo()->lastInsertId();

        return response()->json([
            'data' => [
                'id'          => (int) $id,
                'type'        => $type,
                'occurred_at' => $occurredAt,
            ],
        ], 201);
    }
}
