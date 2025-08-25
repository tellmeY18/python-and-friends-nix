from flask import Flask, jsonify
import redis
import psycopg2
import os
import time
import logging
from typing import Dict, Any

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration with validation
class Config:
    def __init__(self):
        self.redis_host = os.getenv('REDIS_HOST', '127.0.0.1')
        self.redis_port = int(os.getenv('REDIS_PORT', '6379'))
        self.pg_host = os.getenv('PG_HOST', '127.0.0.1')
        self.pg_port = int(os.getenv('PG_PORT', '5432'))
        self.pg_user = os.getenv('POSTGRES_USER', 'postgres')
        self.pg_db = os.getenv('POSTGRES_DB', 'postgres')
        self.pg_password = os.getenv('POSTGRES_PASSWORD', '')
        self.app_port = int(os.getenv('APP_PORT', '80'))
        self.connection_timeout = int(os.getenv('CONNECTION_TIMEOUT', '5'))

        logger.info(f"Config loaded - Redis: {self.redis_host}:{self.redis_port}, "
                   f"PostgreSQL: {self.pg_host}:{self.pg_port}")

config = Config()

@app.route('/')
def index() -> Dict[str, Any]:
    """Main endpoint with service status"""
    redis_status = check_redis()
    postgres_status = check_postgres()

    return jsonify({
        "message": "Nixify Health Check App",
        "version": "1.0.0",
        "services": {
            "redis": redis_status,
            "postgres": postgres_status
        }
    })

@app.route('/health')
def health():
    """Health check endpoint for monitoring"""
    redis_result = check_redis()
    postgres_result = check_postgres()

    redis_healthy = redis_result.get("status") == "healthy"
    postgres_healthy = postgres_result.get("status") == "healthy"

    overall_status = "healthy" if redis_healthy and postgres_healthy else "unhealthy"
    status_code = 200 if overall_status == "healthy" else 503

    return jsonify({
        "status": overall_status,
        "services": {
            "redis": redis_result,
            "postgres": postgres_result
        },
        "timestamp": time.time()
    }), status_code

@app.route('/health/redis')
def health_redis():
    """Redis-specific health check"""
    result = check_redis()
    status_code = 200 if result.get("status") == "healthy" else 503
    return jsonify(result), status_code

@app.route('/health/postgres')
def health_postgres():
    """PostgreSQL-specific health check"""
    result = check_postgres()
    status_code = 200 if result.get("status") == "healthy" else 503
    return jsonify(result), status_code

def check_redis() -> Dict[str, Any]:
    """Check Redis connectivity and basic functionality"""
    try:
        start_time = time.time()
        r = redis.Redis(
            host=config.redis_host,
            port=config.redis_port,
            socket_connect_timeout=config.connection_timeout,
            decode_responses=True
        )

        # Test basic operations
        r.ping()
        test_key = "__health_check__"
        r.set(test_key, "ok", ex=10)  # Expire in 10 seconds
        value = r.get(test_key)
        r.delete(test_key)

        response_time = round((time.time() - start_time) * 1000, 2)

        if value != "ok":
            raise Exception("Redis test operation failed")

        return {
            "status": "healthy",
            "response_time_ms": response_time,
            "host": config.redis_host,
            "port": config.redis_port
        }

    except redis.ConnectionError as e:
        logger.warning(f"Redis connection error: {e}")
        return {
            "status": "unhealthy",
            "error": f"Connection failed: {str(e)}",
            "host": config.redis_host,
            "port": config.redis_port
        }
    except Exception as e:
        logger.error(f"Redis health check failed: {e}")
        return {
            "status": "unhealthy",
            "error": str(e),
            "host": config.redis_host,
            "port": config.redis_port
        }

def check_postgres() -> Dict[str, Any]:
    """Check PostgreSQL connectivity and basic functionality"""
    try:
        start_time = time.time()
        conn_params = {
            "host": config.pg_host,
            "port": config.pg_port,
            "user": config.pg_user,
            "database": config.pg_db,
            "connect_timeout": config.connection_timeout
        }

        if config.pg_password:
            conn_params["password"] = config.pg_password

        conn = psycopg2.connect(**conn_params)
        cursor = conn.cursor()

        # Test basic query
        cursor.execute("SELECT version();")
        version = cursor.fetchone()[0]

        # Test write capability with a temporary table
        cursor.execute("SELECT 1 as health_check;")
        result = cursor.fetchone()[0]

        cursor.close()
        conn.close()

        response_time = round((time.time() - start_time) * 1000, 2)

        if result != 1:
            raise Exception("PostgreSQL test query failed")

        return {
            "status": "healthy",
            "response_time_ms": response_time,
            "host": config.pg_host,
            "port": config.pg_port,
            "version": version.split()[0:2]  # Just PostgreSQL version
        }

    except psycopg2.OperationalError as e:
        logger.warning(f"PostgreSQL connection error: {e}")
        return {
            "status": "unhealthy",
            "error": f"Connection failed: {str(e)}",
            "host": config.pg_host,
            "port": config.pg_port
        }
    except Exception as e:
        logger.error(f"PostgreSQL health check failed: {e}")
        return {
            "status": "unhealthy",
            "error": str(e),
            "host": config.pg_host,
            "port": config.pg_port
        }

@app.errorhandler(Exception)
def handle_exception(e):
    """Global exception handler"""
    logger.error(f"Unhandled exception: {e}")
    return jsonify({
        "status": "error",
        "message": "Internal server error",
        "timestamp": time.time()
    }), 500

if __name__ == '__main__':
    logger.info("Starting Nixify Health Check App...")

    # Wait for services with exponential backoff
    max_retries = 10
    for attempt in range(max_retries):
        redis_ok = check_redis().get("status") == "healthy"
        postgres_ok = check_postgres().get("status") == "healthy"

        if redis_ok and postgres_ok:
            logger.info("All services are healthy, starting Flask app")
            break

        wait_time = min(2 ** attempt, 30)  # Cap at 30 seconds
        logger.info(f"Waiting for services... (attempt {attempt + 1}/{max_retries}, "
                   f"redis: {'ok' if redis_ok else 'not ready'}, "
                   f"postgres: {'ok' if postgres_ok else 'not ready'})")
        time.sleep(wait_time)
    else:
        logger.warning("Services may not be fully ready, but starting app anyway")

    app.run(
        host='0.0.0.0',
        port=config.app_port,
        debug=False
    )
