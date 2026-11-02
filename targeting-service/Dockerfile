# Estágio 1: instalar dependências num venv
FROM python:3.11-slim AS build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Estágio 2: execução
FROM python:3.11-slim
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY app.py .
RUN useradd --create-home --uid 10001 app
USER app
EXPOSE 8003
CMD ["gunicorn", "--bind", "0.0.0.0:8003", "app:app"]