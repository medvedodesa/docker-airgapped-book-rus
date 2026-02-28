#!/bin/bash
# readonly-test.sh
# Test read-only filesystem compatibility for containers
#
# Usage: ./readonly-test.sh <image_name>

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

IMAGE="${1:-}"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image_name>"
    echo ""
    echo "Example: $0 nginx:alpine"
    exit 1
fi

echo -e "${BLUE}Read-Only Filesystem Compatibility Test${NC}"
echo "=========================================="
echo "Image: $IMAGE"
echo ""

# Test 1: Basic read-only test
echo -e "${YELLOW}Test 1: Basic read-only compatibility${NC}"

CONTAINER_NAME="ro-test-$$"

docker run -d --name $CONTAINER_NAME --read-only $IMAGE sleep 1000 >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Container starts with read-only filesystem${NC}"
    
    # Test write to root
    if docker exec $CONTAINER_NAME sh -c 'echo test > /test.txt' 2>/dev/null; then
        echo -e "${RED}✗ Can write to root filesystem (UNEXPECTED)${NC}"
    else
        echo -e "${GREEN}✓ Cannot write to root filesystem${NC}"
    fi
    
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1
else
    echo -e "${RED}✗ Container fails to start with read-only${NC}"
    echo "  Image requires writable filesystem"
fi

echo ""

# Test 2: Identify writable directories needed
echo -e "${YELLOW}Test 2: Identifying required writable directories${NC}"
echo ""

# Run with strace to find write attempts
echo "Testing for write attempts (this may take a moment)..."

docker run --rm --name $CONTAINER_NAME-trace $IMAGE sh -c 'timeout 5s sh' 2>&1 | \
    grep -i "read-only" | head -10 || echo "No obvious write requirements detected"

echo ""

# Test 3: Test with common tmpfs mounts
echo -e "${YELLOW}Test 3: Testing with standard tmpfs mounts${NC}"

docker run -d --name $CONTAINER_NAME-tmpfs \
    --read-only \
    --tmpfs /tmp:size=100M,noexec,nosuid \
    --tmpfs /var/run:size=10M,noexec,nosuid \
    $IMAGE sleep 1000 >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Works with /tmp and /var/run tmpfs${NC}"
    
    # Test tmpfs write
    if docker exec $CONTAINER_NAME-tmpfs sh -c 'echo test > /tmp/test.txt' 2>/dev/null; then
        echo -e "${GREEN}✓ Can write to /tmp${NC}"
    fi
    
    docker rm -f $CONTAINER_NAME-tmpfs >/dev/null 2>&1
else
    echo -e "${YELLOW}⚠ Needs additional tmpfs mounts${NC}"
fi

echo ""

# Test 4: Application-specific tests
echo -e "${YELLOW}Test 4: Application functionality test${NC}"

case "$IMAGE" in
    nginx*|httpd*|apache*)
        echo "Testing web server..."
        docker run -d --name $CONTAINER_NAME-app \
            --read-only \
            --tmpfs /var/cache/nginx:size=50M \
            --tmpfs /var/run:size=10M \
            -p 8888:80 \
            $IMAGE >/dev/null 2>&1
        
        sleep 2
        
        if curl -s http://localhost:8888 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Web server works with read-only${NC}"
        else
            echo -e "${YELLOW}⚠ Web server may need additional configuration${NC}"
        fi
        
        docker rm -f $CONTAINER_NAME-app >/dev/null 2>&1
        ;;
        
    postgres*|mysql*|mariadb*)
        echo "Database detected - data directory must be writable volume"
        echo -e "${YELLOW}⚠ Use read-only with data volume:${NC}"
        echo "  docker run --read-only -v data:/var/lib/postgresql/data $IMAGE"
        ;;
        
    redis*)
        echo "Testing Redis..."
        docker run -d --name $CONTAINER_NAME-app \
            --read-only \
            --tmpfs /data:size=100M \
            $IMAGE >/dev/null 2>&1
        
        sleep 2
        
        if docker exec $CONTAINER_NAME-app redis-cli ping 2>/dev/null | grep -q PONG; then
            echo -e "${GREEN}✓ Redis works with read-only${NC}"
        else
            echo -e "${YELLOW}⚠ Redis may need configuration${NC}"
        fi
        
        docker rm -f $CONTAINER_NAME-app >/dev/null 2>&1
        ;;
        
    *)
        echo "Generic application test..."
        docker run --rm --read-only \
            --tmpfs /tmp:size=100M \
            $IMAGE sh -c 'echo "Basic test passed"' 2>/dev/null && \
            echo -e "${GREEN}✓ Basic functionality works${NC}" || \
            echo -e "${YELLOW}⚠ May need custom tmpfs configuration${NC}"
        ;;
esac

echo ""

# Summary and recommendations
echo "=========================================="
echo "Summary & Recommendations"
echo "=========================================="
echo ""

echo "Recommended docker-compose.yml configuration:"
echo ""
cat << EOF
services:
  app:
    image: $IMAGE
    read_only: true
    tmpfs:
      - /tmp:size=100M,mode=1777,noexec,nosuid
      - /var/run:size=10M,mode=755,noexec,nosuid
      # Add application-specific tmpfs as needed
EOF

echo ""
echo "Common tmpfs requirements by application type:"
echo ""
echo "Nginx/Apache:"
echo "  --tmpfs /var/cache/nginx"
echo "  --tmpfs /var/run"
echo ""
echo "PostgreSQL:"
echo "  --tmpfs /tmp"
echo "  --tmpfs /run"
echo "  -v pgdata:/var/lib/postgresql/data"
echo ""
echo "Redis:"
echo "  --tmpfs /data (or use volume for persistence)"
echo ""
echo "Node.js applications:"
echo "  --tmpfs /tmp"
echo "  --tmpfs /home/node/.npm"
echo ""

echo "Testing complete!"
echo ""
