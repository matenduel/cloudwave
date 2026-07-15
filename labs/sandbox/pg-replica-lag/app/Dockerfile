FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask==3.1.0 prometheus-client==0.21.1 psycopg[binary]==3.2.3
COPY app.py .
CMD ["python", "app.py"]
