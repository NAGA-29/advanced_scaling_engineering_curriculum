# Laravel Legacy Monolith

This directory contains the **existing monolith** used in the
[Strangler Fig pattern](https://martinfowler.com/bliki/StranglerFigApplication.html)
learning exercises. Students strangle this Laravel application incrementally,
moving individual routes to faster Go micro-services while leaving the rest of
the monolith intact.

---

## What this is

A minimal Laravel 10 application backed by MySQL 8. It exposes four JSON API
endpoints that the curriculum's k6 load tests hit. The goal is _not_ a
production-quality Laravel setup; it is a deliberately simple target that is
easy to understand and straightforward to migrate away from.

---

## Prerequisites

| Tool | Version |
|------|---------|
| PHP | 8.2+ |
| Composer | 2.x |
| MySQL | 8.0+ (the `scaling` database from `shared/sql/schema.sql`) |

---

## Setup

```bash
# 1. Install PHP dependencies
composer install

# 2. Copy the environment file and fill in your DB credentials
cp .env.example .env

# 3. Generate the application key
php artisan key:generate

# 4. (Optional) If you want Laravel's own migrations — skip if you already
#    loaded shared/sql/schema.sql
php artisan migrate

# 5. Start the development server
php artisan serve --port=8080
```

> **Note:** run `composer install` after cloning.  The `vendor/` directory is
> intentionally excluded from version control.

---

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/api/health` | Liveness check — returns `{"status":"ok"}` |
| `GET`  | `/api/users/{id}` | Fetch a single user row by primary key |
| `POST` | `/api/heartbeat` | Record a device heartbeat (JSON body: `device_id`, `status`) |
| `POST` | `/api/events` | Append a generic event record |

---

## Environment variables (`.env`)

See `.env.example` for the full list.  The key ones are:

```
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=scaling
DB_USERNAME=root
DB_PASSWORD=secret
```

---

## Strangler Fig exercises

1. **Step 1 – shadow traffic**: stand up the Go service alongside Laravel;
   route a copy of every request to both and compare responses.
2. **Step 2 – cut over one route**: update the load-balancer / API gateway to
   forward `GET /api/users/{id}` to Go, keep everything else on Laravel.
3. **Step 3 – migrate the next route**: repeat for `POST /api/heartbeat`.
4. **Step 4 – decommission**: once all routes are migrated, shut down Laravel.
