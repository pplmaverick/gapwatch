FROM python:3.12-slim

# git is required by `uv sync` to fetch the `rhfeed` dependency, which is
# pinned to a git commit (not a PyPI release) -- python:3.12-slim has no git.
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY main.py ./
COPY src/ ./src/
COPY deployment.json ./

CMD ["uv", "run", "python", "main.py"]
