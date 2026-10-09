<?php
// Simple web application simulating legacy backend service
// Reads config from environment variables (12-Factor App)

$appName = getenv('APP_NAME') ?: 'Legacy-Web-Service';
$appEnv = getenv('APP_ENV') ?: 'production';
$dbHost = getenv('DB_HOST') ?: 'localhost';
$dbPort = getenv('DB_PORT') ?: '3306';
$cacheHost = getenv('CACHE_HOST') ?: 'localhost';

$uri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

// Health check endpoints for Kubernetes probes
if ($uri === '/healthz') {
    http_response_code(200);
    header('Content-Type: application/json');
    echo json_encode(['status' => 'healthy', 'timestamp' => time()]);
    exit;
}

if ($uri === '/readyz') {
    // In production this checks DB/Cache connectivity
    http_response_code(200);
    header('Content-Type: application/json');
    echo json_encode([
        'status' => 'ready',
        'db_host' => $dbHost,
        'cache_host' => $cacheHost,
        'timestamp' => time()
    ]);
    exit;
}

// Default application route
header('Content-Type: application/json');
echo json_encode([
    'service' => $appName,
    'environment' => $appEnv,
    'message' => 'Service operational on Kubernetes',
    'version' => '1.0.0',
    'hostname' => gethostname(),
    'client_ip' => $_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? 'unknown',
    'time' => date('c')
], JSON_PRETTY_PRINT);
