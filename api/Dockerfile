FROM python:3.12-slim

# 로그가 버퍼링 없이 즉시 stdout으로 나오도록 (docker logs 실시간 확인)
ENV PYTHONUNBUFFERED=1

WORKDIR /srv

# 의존성 레이어를 소스와 분리 -> 코드만 바뀌면 pip install 캐시 재사용
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# 컨테이너 내부 권한 최소화.
# 이 앱은 특권 포트도, 파일 쓰기도 필요 없으므로 root로 돌 이유가 없다.
# 침해 시 컨테이너 내에서의 행동 반경을 줄이는 기본 방어선.
RUN useradd --no-create-home --shell /usr/sbin/nologin appuser
USER appuser

EXPOSE 8000

# 반드시 exec form(JSON 배열)이어야 한다.
# shell form(CMD uvicorn ...)은 PID 1이 쉘이 되어 SIGTERM을 uvicorn에
# 전달하지 않는다. 그러면 docker stop 시 lifespan shutdown이 실행되지 못하고
# 10초 뒤 SIGKILL -> producer 버퍼의 로그가 flush 없이 유실된다.
# exec form이어야 SIGTERM -> lifespan -> producer.stop() -> flush 경로가 성립한다.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]