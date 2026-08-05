import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Response, status

from app.config import settings
from app.producer import producer
from app.schemas import IngestResponse, LogEvent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("log-api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup: Producer 연결을 애플리케이션 기동 시 1회만 수립
    await producer.start()
    yield
    # shutdown: SIGTERM 수신 시 잔여 배치 flush 후 종료
    await producer.stop()


app = FastAPI(
    title="Game Log Ingestion API",
    description="인게임 로그를 수신해 Kafka로 위임하는 수집 게이트웨이",
    version="1.0.0",
    lifespan=lifespan,
)


@app.post(
    "/api/v1/logs",
    response_model=IngestResponse,
    status_code=status.HTTP_200_OK,
    summary="게임 로그 수집",
)
async def ingest_log(event: LogEvent):
    # mode="json" -> datetime을 ISO 8601 문자열로 직렬화
    record = event.model_dump(mode="json")
    # 클라이언트 시각(timestamp)과 구분되는 서버 수신 시각.
    # 클라이언트 시계는 신뢰할 수 없으므로 파이프라인 지연 측정의 기준으로 쓴다.
    record["ingested_at"] = datetime.now(timezone.utc).isoformat()

    try:
        meta = await producer.send(record, key=event.user_id)
    except Exception as exc:
        # 큐 전송에 실패했는데 200을 주면 클라이언트는 성공으로 오인하고
        # 재시도하지 않는다. 그 순간 로그는 확정적으로 유실된다.
        # 따라서 503을 반환해 재시도 책임을 클라이언트로 되돌린다.
        logger.error("failed to publish log: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="log pipeline temporarily unavailable",
        ) from exc

    return IngestResponse(
        topic=meta.topic,
        partition=meta.partition,
        offset=meta.offset,
    )


@app.get("/health", summary="헬스체크")
async def health(response: Response):
    """docker-compose healthcheck / ALB Target Group 대상.

    Producer가 준비되지 않은 상태에서 503을 반환해야
    ALB가 트래픽을 보내지 않고, compose의 depends_on도 대기한다.
    """
    if not producer.is_ready:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "unavailable", "kafka_producer": "not_ready"}
    return {"status": "ok", "env": settings.app_env}