from flask import Flask, jsonify, request, send_file, render_template_string
import redis
import psycopg2
import boto3
from botocore.exceptions import ClientError
import os
import time
import logging
from typing import Dict, Any
from werkzeug.utils import secure_filename
import uuid
from io import BytesIO

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

        # S3/Garage configuration - initialize first
        self.s3_endpoint = os.getenv('GARAGE_S3_ENDPOINT', 'http://127.0.0.1:3900')
        self.s3_region = os.getenv('GARAGE_S3_REGION', 'garage')
        self.aws_access_key = os.getenv('AWS_ACCESS_KEY_ID')
        self.aws_secret_key = os.getenv('AWS_SECRET_ACCESS_KEY')
        self.s3_bucket = os.getenv('S3_BUCKET', 'default-bucket')
        self.credentials_file = '/data/garage/credentials.env'

        # Load credentials from file if environment variables are not set
        self._load_s3_credentials()

    def _load_s3_credentials(self):
        """Load S3 credentials from environment or file"""
        if not self.aws_access_key or not self.aws_secret_key:
            # Try to load from credentials file
            if os.path.exists(self.credentials_file):
                try:
                    with open(self.credentials_file, 'r') as f:
                        for line in f:
                            if '=' in line:
                                key, value = line.strip().split('=', 1)
                                if key == 'AWS_ACCESS_KEY_ID':
                                    self.aws_access_key = value
                                elif key == 'AWS_SECRET_ACCESS_KEY':
                                    self.aws_secret_key = value
                except Exception as e:
                    logger.warning(f"Failed to load S3 credentials from file: {e}")

        logger.info(f"Config loaded - Redis: {self.redis_host}:{self.redis_port}, "
                   f"PostgreSQL: {self.pg_host}:{self.pg_port}, "
                   f"S3: {self.s3_endpoint}")

config = Config()

def load_credentials_from_file():
    """Load S3 credentials from file if available"""
    credentials_file = '/data/garage/credentials.env'
    if os.path.exists(credentials_file):
        try:
            with open(credentials_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        os.environ[key] = value
            return True
        except Exception as e:
            logger.warning(f"Failed to load credentials from file: {e}")
    return False

# Initialize S3 client (will be created when credentials are available)
s3_client = None

def get_s3_client():
    """Get or create S3 client with current credentials"""
    global s3_client

    # Load credentials if not already loaded
    if not config.aws_access_key or not config.aws_secret_key:
        load_credentials_from_file()
        config.aws_access_key = os.getenv('AWS_ACCESS_KEY_ID')
        config.aws_secret_key = os.getenv('AWS_SECRET_ACCESS_KEY')

    if config.aws_access_key and config.aws_secret_key:
        if s3_client is None:
            try:
                s3_client = boto3.client(
                    's3',
                    endpoint_url=config.s3_endpoint,
                    aws_access_key_id=config.aws_access_key,
                    aws_secret_access_key=config.aws_secret_key,
                    region_name=config.s3_region
                )
                logger.info(f"S3 client initialized with key: {config.aws_access_key}")
            except Exception as e:
                logger.error(f"Failed to initialize S3 client: {e}")
                return None
        return s3_client
    else:
        logger.warning("S3 credentials not available")
        return None

# HTML template for file upload interface
UPLOAD_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Nixify Health Check - File Upload</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
        .upload-area { border: 2px dashed #ccc; padding: 20px; text-align: center; margin: 20px 0; }
        .file-list { margin: 20px 0; }
        .file-item { border: 1px solid #ddd; padding: 10px; margin: 10px 0; border-radius: 5px; }
        .btn { padding: 10px 20px; background: #007bff; color: white; border: none; border-radius: 5px; cursor: pointer; }
        .btn:hover { background: #0056b3; }
        .status { padding: 10px; margin: 10px 0; border-radius: 5px; }
        .status.healthy { background: #d4edda; color: #155724; }
        .status.unhealthy { background: #f8d7da; color: #721c24; }
    </style>
</head>
<body>
    <h1>Nixify Health Check</h1>

    <div class="status {{ redis_status }}">
        Redis: {{ redis_message }}
    </div>
    <div class="status {{ postgres_status }}">
        PostgreSQL: {{ postgres_message }}
    </div>
    <div class="status {{ s3_status }}">
        S3 Storage: {{ s3_message }}
    </div>

    <h2>File Upload</h2>
    <form method="post" enctype="multipart/form-data" action="/upload">
        <div class="upload-area">
            <input type="file" name="file" required>
            <br><br>
            <button type="submit" class="btn">Upload File</button>
        </div>
    </form>

    <h2>Uploaded Files</h2>
    <div class="file-list">
        {% for file in files %}
        <div class="file-item">
            <strong>{{ file.filename }}</strong> ({{ file.size }} bytes)
            <br>
            Uploaded: {{ file.upload_date }}
            <br>
            <a href="/file/{{ file.key }}" class="btn" target="_blank">Download</a>
            {% if file.is_image %}
            <a href="/preview/{{ file.key }}" class="btn" target="_blank">Preview</a>
            {% endif %}
        </div>
        {% endfor %}
    </div>
</body>
</html>
"""

@app.route('/')
def index():
    """Main web interface with file upload"""
    redis_result = check_redis()
    postgres_result = check_postgres()
    s3_result = check_s3()

    files = list_uploaded_files()

    return render_template_string(UPLOAD_TEMPLATE,
        redis_status="healthy" if redis_result.get("status") == "healthy" else "unhealthy",
        redis_message=f"Connected to {config.redis_host}:{config.redis_port}",
        postgres_status="healthy" if postgres_result.get("status") == "healthy" else "unhealthy",
        postgres_message=f"Connected to {config.pg_host}:{config.pg_port}",
        s3_status="healthy" if s3_result.get("status") == "healthy" else "unhealthy",
        s3_message=f"Connected to {config.s3_endpoint}",
        files=files
    )

@app.route('/api')
def api_status() -> Dict[str, Any]:
    """API endpoint with service status"""
    redis_status = check_redis()
    postgres_status = check_postgres()
    s3_status = check_s3()

    return jsonify({
        "message": "Nixify Health Check App",
        "version": "1.0.0",
        "services": {
            "redis": redis_status,
            "postgres": postgres_status,
            "s3": s3_status
        }
    })

@app.route('/health')
def health():
    """Health check endpoint for monitoring"""
    redis_result = check_redis()
    postgres_result = check_postgres()
    s3_result = check_s3()

    redis_healthy = redis_result.get("status") == "healthy"
    postgres_healthy = postgres_result.get("status") == "healthy"
    s3_healthy = s3_result.get("status") == "healthy"

    overall_status = "healthy" if redis_healthy and postgres_healthy and s3_healthy else "unhealthy"
    status_code = 200 if overall_status == "healthy" else 503

    return jsonify({
        "status": overall_status,
        "services": {
            "redis": redis_result,
            "postgres": postgres_result,
            "s3": s3_result
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

@app.route('/health/s3')
def health_s3():
    """S3/Garage-specific health check"""
    result = check_s3()
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

def check_s3() -> Dict[str, Any]:
    """Check S3/Garage connectivity and basic functionality"""
    try:
        start_time = time.time()

        # Get S3 client (may return None if credentials not available)
        client = get_s3_client()
        if client is None:
            return {
                "status": "unhealthy",
                "error": "S3 credentials not available",
                "endpoint": config.s3_endpoint
            }

        # Test bucket access
        client.head_bucket(Bucket=config.s3_bucket)

        # Test write operation
        test_key = f"__health_check_{int(time.time())}.txt"
        client.put_object(
            Bucket=config.s3_bucket,
            Key=test_key,
            Body=b"health check",
            ContentType="text/plain"
        )

        # Test read operation
        response = client.get_object(Bucket=config.s3_bucket, Key=test_key)
        content = response['Body'].read()

        # Cleanup
        client.delete_object(Bucket=config.s3_bucket, Key=test_key)

        response_time = round((time.time() - start_time) * 1000, 2)

        if content != b"health check":
            raise Exception("S3 test operation failed")

        return {
            "status": "healthy",
            "response_time_ms": response_time,
            "endpoint": config.s3_endpoint,
            "bucket": config.s3_bucket
        }

    except ClientError as e:
        logger.warning(f"S3 client error: {e}")
        return {
            "status": "unhealthy",
            "error": f"S3 error: {str(e)}",
            "endpoint": config.s3_endpoint
        }
    except Exception as e:
        logger.error(f"S3 health check failed: {e}")
        return {
            "status": "unhealthy",
            "error": str(e),
            "endpoint": config.s3_endpoint
        }

@app.route('/upload', methods=['POST'])
def upload_file():
    """Handle file upload to S3"""
    if 'file' not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files['file']
    if file.filename == '':
        return jsonify({"error": "No file selected"}), 400

    try:
        # Get S3 client
        client = get_s3_client()
        if client is None:
            return jsonify({"error": "S3 service not available"}), 503

        # Generate unique key for the file
        filename = secure_filename(file.filename)
        unique_key = f"{uuid.uuid4()}_{filename}"

        # Upload to S3
        client.put_object(
            Bucket=config.s3_bucket,
            Key=unique_key,
            Body=file.read(),
            ContentType=file.content_type or 'application/octet-stream',
            Metadata={
                'original-filename': filename,
                'upload-timestamp': str(int(time.time()))
            }
        )

        logger.info(f"File uploaded successfully: {unique_key}")
        return jsonify({
            "message": "File uploaded successfully",
            "key": unique_key,
            "filename": filename
        })

    except Exception as e:
        logger.error(f"File upload failed: {e}")
        return jsonify({"error": f"Upload failed: {str(e)}"}), 500

@app.route('/file/<key>')
def download_file(key):
    """Download file from S3"""
    try:
        client = get_s3_client()
        if client is None:
            return jsonify({"error": "S3 service not available"}), 503

        response = client.get_object(Bucket=config.s3_bucket, Key=key)

        # Get original filename from metadata
        metadata = response.get('Metadata', {})
        filename = metadata.get('original-filename', key)

        # Create file-like object
        file_obj = BytesIO(response['Body'].read())

        return send_file(
            file_obj,
            as_attachment=True,
            download_name=filename,
            mimetype=response.get('ContentType', 'application/octet-stream')
        )

    except ClientError as e:
        if e.response['Error']['Code'] == 'NoSuchKey':
            return jsonify({"error": "File not found"}), 404
        return jsonify({"error": f"Download failed: {str(e)}"}), 500
    except Exception as e:
        logger.error(f"File download failed: {e}")
        return jsonify({"error": f"Download failed: {str(e)}"}), 500

@app.route('/preview/<key>')
def preview_file(key):
    """Preview file (for images) from S3"""
    try:
        client = get_s3_client()
        if client is None:
            return jsonify({"error": "S3 service not available"}), 503

        response = client.get_object(Bucket=config.s3_bucket, Key=key)
        content_type = response.get('ContentType', 'application/octet-stream')

        # Only preview images
        if not content_type.startswith('image/'):
            return jsonify({"error": "File is not an image"}), 400

        file_obj = BytesIO(response['Body'].read())

        return send_file(
            file_obj,
            mimetype=content_type
        )

    except ClientError as e:
        if e.response['Error']['Code'] == 'NoSuchKey':
            return jsonify({"error": "File not found"}), 404
        return jsonify({"error": f"Preview failed: {str(e)}"}), 500
    except Exception as e:
        logger.error(f"File preview failed: {e}")
        return jsonify({"error": f"Preview failed: {str(e)}"}), 500

def list_uploaded_files():
    """List all uploaded files from S3"""
    try:
        client = get_s3_client()
        if client is None:
            return []

        response = client.list_objects_v2(Bucket=config.s3_bucket)
        files = []

        for obj in response.get('Contents', []):
            # Skip health check files
            if obj['Key'].startswith('__health_check'):
                continue

            # Get object metadata
            try:
                head_response = client.head_object(Bucket=config.s3_bucket, Key=obj['Key'])
                metadata = head_response.get('Metadata', {})
                content_type = head_response.get('ContentType', 'application/octet-stream')

                files.append({
                    'key': obj['Key'],
                    'filename': metadata.get('original-filename', obj['Key']),
                    'size': obj['Size'],
                    'upload_date': obj['LastModified'].strftime('%Y-%m-%d %H:%M:%S'),
                    'is_image': content_type.startswith('image/')
                })
            except Exception as e:
                logger.warning(f"Failed to get metadata for {obj['Key']}: {e}")
                files.append({
                    'key': obj['Key'],
                    'filename': obj['Key'],
                    'size': obj['Size'],
                    'upload_date': obj['LastModified'].strftime('%Y-%m-%d %H:%M:%S'),
                    'is_image': False
                })

        return sorted(files, key=lambda x: x['upload_date'], reverse=True)

    except Exception as e:
        logger.error(f"Failed to list files: {e}")
        return []

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
        s3_ok = check_s3().get("status") == "healthy"

        if redis_ok and postgres_ok and s3_ok:
            logger.info("All services are healthy, starting Flask app")
            break

        wait_time = min(2 ** attempt, 30)  # Cap at 30 seconds
        logger.info(f"Waiting for services... (attempt {attempt + 1}/{max_retries}, "
                   f"redis: {'ok' if redis_ok else 'not ready'}, "
                   f"postgres: {'ok' if postgres_ok else 'not ready'}, "
                   f"s3: {'ok' if s3_ok else 'not ready'})")
        time.sleep(wait_time)
    else:
        logger.warning("Services may not be fully ready, but starting app anyway")

    app.run(
        host='0.0.0.0',
        port=config.app_port,
        debug=False
    )
