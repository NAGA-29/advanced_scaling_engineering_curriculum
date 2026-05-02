-- Seed data: 10 sample devices spread across 3 tenants
-- Run AFTER schema.sql

USE scaling;

INSERT INTO devices (tenant_id, device_id, name, created_at, updated_at) VALUES
-- Tenant 1 – "Acme Corp"
(1, 'dev-acme-001', 'Acme Temperature Sensor A',  NOW(), NOW()),
(1, 'dev-acme-002', 'Acme Temperature Sensor B',  NOW(), NOW()),
(1, 'dev-acme-003', 'Acme Door Controller',        NOW(), NOW()),
(1, 'dev-acme-004', 'Acme HVAC Monitor',           NOW(), NOW()),

-- Tenant 2 – "Globex Industries"
(2, 'dev-globex-001', 'Globex Pressure Gauge 1',   NOW(), NOW()),
(2, 'dev-globex-002', 'Globex Pressure Gauge 2',   NOW(), NOW()),
(2, 'dev-globex-003', 'Globex Flow Meter',         NOW(), NOW()),

-- Tenant 3 – "Initech"
(3, 'dev-initech-001', 'Initech Humidity Sensor',  NOW(), NOW()),
(3, 'dev-initech-002', 'Initech Motion Detector',  NOW(), NOW()),
(3, 'dev-initech-003', 'Initech Power Monitor',    NOW(), NOW());
