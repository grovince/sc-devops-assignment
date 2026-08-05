import json
import logging

from aiokafka import AIOKafkaProducer

from app.config import settings

logger = logging.getLogger(__name__)


def _serialize_value(value: dict) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _serialize_key(key: str | None) -> bytes | None:
    return key.encode("utf-8") if key else None


class KafkaLogProducer:
    """Producer를 애플리케이션 전 생애주기에 걸쳐 '단 하나만' 유지한다.

    요청마다 Producer를 생성하면 매번 TCP 연결과 메타데이터 조회가 발생하고,
    내부 배치 버퍼를 쓸 수 없어 브로커 왕복이 요청 수만큼 그대로 발생한다.
    """

    def __init__(self) -> None:
        self._producer: AIOKafkaProducer | None = None

    @property
    def is_ready(self) -> bool:
        return self._producer is not None

    async def start(self) -> None:
        self._producer = AIOKafkaProducer(
            bootstrap_servers=settings.kafka_bootstrap_servers,
            acks=settings.kafka_acks,
            enable_idempotence=settings.kafka_enable_idempotence,
            request_timeout_ms=settings.kafka_request_timeout_ms,
            compression_type="gzip",
            value_serializer=_serialize_value,
            key_serializer=_serialize_key,
        )
        await self._producer.start()
        logger.info(
            "kafka producer started (servers=%s, topic=%s, acks=%s, idempotence=%s)",
            settings.kafka_bootstrap_servers,
            settings.kafka_topic,
            settings.kafka_acks,
            settings.kafka_enable_idempotence,
        )

    async def stop(self) -> None:
        """Graceful shutdown.

        AIOKafkaProducer.stop()은 내부적으로 버퍼에 남은 배치를 flush한 뒤
        연결을 닫는다. SIGTERM -> lifespan shutdown -> stop() 경로가 보장되어야
        컨테이너 롤링 업데이트 시점의 유실이 없다.

        이 경로를 단순하게 유지하기 위해 Gunicorn 마스터 프로세스를 두지 않고
        '1 Container = 1 Uvicorn' 구조로 replica 수평 확장을 택했다.
        """
        if self._producer is None:
            return
        await self._producer.stop()
        self._producer = None
        logger.info("kafka producer stopped (buffer flushed)")

    async def send(self, event: dict, key: str | None = None):
        """브로커의 ack를 기다린 뒤 메타데이터를 반환한다.

        send_and_wait()은 이름 그대로 ack를 '기다린다'. 다만 대기 중
        이벤트 루프가 블로킹되지 않으므로 그 사이 다른 요청을 계속 처리한다.
        (지연이 없는 것이 아니라, 기다리는 동안 놀지 않는 것)

        fire-and-forget(send() 후 즉시 200)보다 응답이 느리지만,
        전송 실패를 클라이언트가 성공으로 오인하지 않는다.
        '유실 없이'라는 요구를 지연보다 우선한 결과다.
        """
        if self._producer is None:
            raise RuntimeError("producer is not started")

        return await self._producer.send_and_wait(
            settings.kafka_topic,
            value=event,
            key=key,
        )


producer = KafkaLogProducer()