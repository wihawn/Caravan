# CPU image for the inference service. Docker isn't installed on the dev Mac; `make up` runs it natively.
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
COPY inference/requirements.txt inference/requirements.txt
RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu -r inference/requirements.txt
COPY inference inference
EXPOSE 8766
CMD ["uvicorn", "inference.app:app", "--host", "0.0.0.0", "--port", "8766"]
