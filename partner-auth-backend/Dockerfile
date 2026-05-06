FROM python:3.12-slim

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Copy project definition and lock file
COPY pyproject.toml uv.lock ./

# Install dependencies (no dev deps in production)
RUN uv sync --no-dev --frozen

# Copy application code
COPY . .

# Create directory for SQLite database
RUN mkdir -p /data

# Set default environment variables
ENV DATABASE_PATH=/data/tokens.db
ENV LOG_LEVEL=INFO

# Expose the application port
EXPOSE 8000

# Run the application
CMD ["uv", "run", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
