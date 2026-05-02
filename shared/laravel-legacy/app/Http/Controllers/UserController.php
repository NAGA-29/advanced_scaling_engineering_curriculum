<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

/**
 * UserController
 *
 * Handles read access to the `users` table.
 * Uses raw DB queries (no Eloquent model file needed) so the controller is
 * self-contained and easy to follow in a workshop setting.
 */
class UserController extends Controller
{
    /**
     * GET /api/users
     *
     * Returns a paginated list of users.
     * Accepts optional query parameters:
     *   ?tenant_id=1   – filter by tenant
     *   ?page=1        – page number (default 1)
     *   ?per_page=50   – page size    (default 50, max 500)
     */
    public function index(Request $request): JsonResponse
    {
        $perPage   = min((int) $request->query('per_page', 50), 500);
        $page      = max((int) $request->query('page', 1), 1);
        $tenantId  = $request->query('tenant_id');

        $offset = ($page - 1) * $perPage;

        $query  = 'SELECT id, tenant_id, name, email, created_at, updated_at FROM users';
        $params = [];

        if ($tenantId !== null) {
            $query   .= ' WHERE tenant_id = ?';
            $params[] = (int) $tenantId;
        }

        $query .= ' ORDER BY id ASC LIMIT ? OFFSET ?';
        $params[] = $perPage;
        $params[] = $offset;

        $users = DB::select($query, $params);

        // Total count for the chosen filter (cheap index scan on tenant_id).
        $countQuery  = 'SELECT COUNT(*) AS total FROM users';
        $countParams = [];
        if ($tenantId !== null) {
            $countQuery   .= ' WHERE tenant_id = ?';
            $countParams[] = (int) $tenantId;
        }
        $total = DB::selectOne($countQuery, $countParams)->total ?? 0;

        return response()->json([
            'data' => $users,
            'meta' => [
                'page'     => $page,
                'per_page' => $perPage,
                'total'    => (int) $total,
            ],
        ]);
    }

    /**
     * GET /api/users/{id}
     *
     * Returns a single user by primary key.
     * Returns 404 JSON if the user does not exist.
     */
    public function show(int $id): JsonResponse
    {
        $user = DB::selectOne(
            'SELECT id, tenant_id, name, email, created_at, updated_at
               FROM users
              WHERE id = ?
              LIMIT 1',
            [$id]
        );

        if ($user === null) {
            return response()->json(['error' => 'User not found'], 404);
        }

        return response()->json(['data' => $user]);
    }
}
