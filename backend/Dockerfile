# CampusSync backend - production image.
#
# The build context is the REPOSITORY ROOT (Render's default), because the
# backend lives in backend/ while the rest of the build needs nothing from the
# Flutter app:
#
#   docker build -f backend/Dockerfile -t campussync-backend .
#   docker run -p 8000:8000 -v campussync-data:/data campussync-backend
#
# A root .dockerignore keeps .env, the SQLite database and the local venv out
# of the image even though the whole backend directory is copied.

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first: a code change then only rebuilds the last two layers.
COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./

# Persistent data. The image creates the mount point; attach a disk/volume at
# /data on the host (see DEPLOYMENT.md). Everything outside that mount is lost
# on redeploy, so uploads live there too - config.py picks up
# sqlite:////data/campussync.db automatically when /data exists.
RUN mkdir -p /data
ENV UPLOAD_DIR=/data/uploads

EXPOSE 8000

# Render/Railway/Fly inject $PORT; the fallback keeps `docker run -p 8000:8000`
# working. One worker only: SQLite plus a single-instance disk cannot be shared.
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
