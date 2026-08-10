FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# named volume이 비어 있으면 Docker가 이미지의 해당 경로에서 소유권까지
# 복사해 볼륨을 초기화한다. 이 chown이 마운트 이후 볼륨 권한을 결정한다.
# (없으면 볼륨이 root:root로 생겨 appuser가 쓰기에 실패한다)
RUN useradd --no-create-home --shell /usr/sbin/nologin appuser \
    && mkdir -p /data/logs && chown appuser:appuser /data/logs
USER appuser

# exec form이어야 PID 1이 파이썬이 되어 docker stop 시 즉시 종료된다.
CMD ["python", "main.py"]