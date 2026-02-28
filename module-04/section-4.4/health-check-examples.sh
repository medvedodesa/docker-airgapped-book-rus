#!/bin/bash
# health-check-examples.sh
# Examples of various health check implementations
#
# Usage: ./health-check-examples.sh

cat << 'EOF'
# ============================================
# Docker Health Check Examples
# ============================================

# ============================================
# 1. HTTP Health Check (Web Applications)
# ============================================

# Simple HTTP check
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# With custom headers
HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -f -H "X-Health-Check: true" http://localhost:8080/health || exit 1

# Using wget (if curl not available)
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/health || exit 1

# ============================================
# 2. TCP Port Check
# ============================================

# Check if port is listening
HEALTHCHECK --interval=30s --timeout=3s \
    CMD nc -z localhost 8080 || exit 1

# Alternative with timeout
HEALTHCHECK --interval=30s --timeout=3s \
    CMD timeout 2 bash -c "</dev/tcp/localhost/8080" || exit 1

# ============================================
# 3. Database Health Checks
# ============================================

# PostgreSQL
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s \
    CMD pg_isready -U postgres || exit 1

# MySQL/MariaDB
HEALTHCHECK --interval=30s --timeout=3s \
    CMD mysqladmin ping -h localhost || exit 1

# Redis
HEALTHCHECK --interval=30s --timeout=3s \
    CMD redis-cli ping | grep PONG || exit 1

# MongoDB
HEALTHCHECK --interval=30s --timeout=3s \
    CMD mongo --eval "db.adminCommand('ping')" || exit 1

# ============================================
# 4. Process-Based Health Checks
# ============================================

# Check if process is running
HEALTHCHECK --interval=30s --timeout=3s \
    CMD pgrep -f "python app.py" > /dev/null || exit 1

# Check specific service
HEALTHCHECK --interval=30s --timeout=3s \
    CMD ps aux | grep -v grep | grep nginx || exit 1

# ============================================
# 5. File-Based Health Checks
# ============================================

# Check if ready file exists
HEALTHCHECK --interval=30s --timeout=3s \
    CMD test -f /app/ready || exit 1

# Check file modification time (app is active)
HEALTHCHECK --interval=30s --timeout=3s \
    CMD find /app/heartbeat -mmin -2 || exit 1

# ============================================
# 6. Multi-Step Health Checks
# ============================================

# Comprehensive check
HEALTHCHECK --interval=30s --timeout=5s \
    CMD /bin/sh -c ' \
        curl -f http://localhost:8080/health && \
        test -f /app/ready && \
        pgrep -f "python app.py" > /dev/null \
    ' || exit 1

# With custom health script
HEALTHCHECK --interval=30s --timeout=5s \
    CMD /app/health-check.sh

# ============================================
# 7. Security-Focused Health Checks
# ============================================

# Check for unexpected processes
HEALTHCHECK --interval=30s --timeout=5s \
    CMD /bin/sh -c ' \
        PROCS=$(ps aux | grep -v "grep\|ps\|sh\|health" | wc -l); \
        if [ "$PROCS" -gt 5 ]; then \
            echo "Unexpected processes detected"; \
            exit 1; \
        fi; \
        curl -f http://localhost:8080/health \
    ' || exit 1

# Verify file checksums
HEALTHCHECK --interval=30s --timeout=5s \
    CMD /bin/sh -c ' \
        md5sum -c /app/.checksums && \
        curl -f http://localhost:8080/health \
    ' || exit 1

# ============================================
# 8. docker-compose.yml Examples
# ============================================

# Example 1: Simple web app
services:
  web:
    image: nginx
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/health"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 10s

# Example 2: Database
services:
  db:
    image: postgres:15
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 40s

# Example 3: Multi-step check
services:
  app:
    image: myapp
    healthcheck:
      test: |
        /bin/sh -c '
        curl -f http://localhost:8080/health &&
        test -f /app/ready &&
        pgrep -f "python" > /dev/null
        '
      interval: 30s
      timeout: 5s
      retries: 3

# ============================================
# 9. Application Health Endpoint Examples
# ============================================

# Python Flask
"""
from flask import Flask, jsonify
import psutil

app = Flask(__name__)

@app.route('/health')
def health():
    # Check dependencies
    try:
        # Database check
        db.execute("SELECT 1")
        
        # Disk space check
        disk = psutil.disk_usage('/')
        if disk.percent > 90:
            return jsonify({"status": "unhealthy", "reason": "disk space"}), 503
        
        # Memory check
        mem = psutil.virtual_memory()
        if mem.percent > 90:
            return jsonify({"status": "unhealthy", "reason": "memory"}), 503
        
        return jsonify({"status": "healthy"}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "reason": str(e)}), 503
"""

# Node.js Express
"""
app.get('/health', async (req, res) => {
  try {
    // Check database
    await db.query('SELECT 1');
    
    // Check Redis
    await redis.ping();
    
    // Check dependencies
    const checks = await Promise.all([
      checkDatabase(),
      checkCache(),
      checkDiskSpace()
    ]);
    
    if (checks.every(c => c.healthy)) {
      res.status(200).json({ status: 'healthy' });
    } else {
      res.status(503).json({ status: 'unhealthy', checks });
    }
  } catch (error) {
    res.status(503).json({ status: 'unhealthy', error: error.message });
  }
});
"""

# ============================================
# 10. Custom Health Check Scripts
# ============================================

# Standalone health check script
#!/bin/bash
# /app/health-check.sh

set -e

# Check HTTP endpoint
curl -f http://localhost:8080/health >/dev/null 2>&1

# Check process
pgrep -f "app.py" >/dev/null

# Check disk space
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 90 ]; then
    echo "Disk usage too high: ${DISK_USAGE}%"
    exit 1
fi

# Check memory
MEM_AVAILABLE=$(free | grep Mem | awk '{print $7}')
if [ "$MEM_AVAILABLE" -lt 100000 ]; then
    echo "Low memory"
    exit 1
fi

echo "Health check passed"
exit 0

# ============================================
# 11. Monitoring Health Status
# ============================================

# Check health status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Filter unhealthy containers
docker ps --filter "health=unhealthy"

# Get detailed health info
docker inspect mycontainer --format='{{json .State.Health}}' | jq

# Watch health status
watch -n 5 'docker ps --format "table {{.Names}}\t{{.Status}}"'

# ============================================
# 12. Alerting on Health Failures
# ============================================

# Monitor script (cron every 5 minutes)
#!/bin/bash
for CONTAINER in $(docker ps -q); do
    HEALTH=$(docker inspect $CONTAINER --format='{{.State.Health.Status}}')
    NAME=$(docker inspect $CONTAINER --format='{{.Name}}')
    
    if [ "$HEALTH" = "unhealthy" ]; then
        # Send alert
        echo "ALERT: $NAME is unhealthy" | mail -s "Container Health Alert" admin@company.com
        
        # Optional: Auto-restart
        # docker restart $CONTAINER
    fi
done

# ============================================
# Best Practices
# ============================================

# 1. Start period
#    Use start_period for applications with slow startup
#    start_period: 40s for databases, 10s for web apps

# 2. Interval
#    30s is good default
#    Increase for resource-intensive checks
#    Decrease for critical services needing fast detection

# 3. Timeout
#    3s is usually sufficient
#    Increase for slow checks

# 4. Retries
#    3 retries prevents false positives
#    Adjust based on tolerance for downtime

# 5. Check complexity
#    Keep checks lightweight
#    Don't perform expensive operations
#    Consider separate monitoring for deep checks

# 6. Return codes
#    0 = healthy
#    1 = unhealthy
#    2 = reserved (Docker internal)

EOF
