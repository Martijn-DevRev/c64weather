FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

EXPOSE 8888

ENTRYPOINT ["python3", "server.py"]
CMD ["--port", "8888"]
