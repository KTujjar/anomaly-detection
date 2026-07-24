FROM python:3.11-slim

WORKDIR /app

# Install dependencies first (separate layer so it caches across code changes).
#
# torch comes from the CPU wheel index: the default PyPI wheel bundles the
# NVIDIA CUDA runtime (cuDNN, cuBLAS, NCCL) which adds several GB to the image
# and is dead weight on a CPU-only Kubernetes node.
#
# requirements-serving.txt is the runtime subset — no jupyter, matplotlib,
# seaborn, pytest or httpx, none of which are imported by src/.
COPY requirements-serving.txt .
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir -r requirements-serving.txt

# Copy source and pre-trained artifacts
COPY src/ ./src/
COPY artifacts/ ./artifacts/

# Non-root user for security
RUN useradd -m appuser && chown -R appuser /app
USER appuser

EXPOSE 8080

CMD ["uvicorn", "src.serving.api:app", "--host", "0.0.0.0", "--port", "8080"]
