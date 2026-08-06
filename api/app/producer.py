import asyncio
import json
import logging

from aiokafka import AIOKafkaProducer
from aiokafka.errors import KafkaConnectionError

from app.config import settings

logger = logging.getLogger(__name__)


def _serialize_value(value: dict) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _serialize_key(key: str | None) -> bytes | None:
    # truthy 체크(if key)를 쓰면 빈 문자열이 조용히 '키 없음'
    # (라운드로빈 파티셔닝)으로 바뀌므로 None만 명시적으로 거른다.
    # (빈 문자열 자체는 스키마의 min_length=1이 이미 막고 있다.)
    return key.encode("utf-8") if key is not None else None


class KafkaLogProducer:
    """Producer를 애플리케이션 전 생애주기에 걸쳐 '단 하나만' 유지한다.

    요청마다 Producer를 생성하면 매번 TCP 연결과 메타데이터 조회가 발생하고,
    내부 배치 버퍼를 쓸 수 없어 브로커 왕복이 요청 수만큼 그대로 발생한다.
    """

    def __init__(self) -> None:
        self._producer: AIOKafkaProducer | None = None

    @property
    def is_ready(self) -> bool:
        # 한계: 'start 성공 여부'만 반영하며, 이후의 브로커 연결 상태까지
        # 보장하지는 않는다. 헬스체크마다 실제 브로커 왕복을 하는 것은
        # 그것대로 부하이므로 실용적 타협이다. (README에 명시)
        return self._producer is not None

    async def start(self) -> None:
        producer = AIOKafkaProducer(
            bootstrap_servers=settings.kafka_bootstrap_servers,
            # ---- 설계 결정: 설정으로 열어두지 않고 고정 ----
            # '유실 없이'가 이 서비스의 존재 이유다.
            # enable_idempotence=True는 acks="all"을 강제한다(세트 옵션).
            #   - acks="all": ISR 복제까지 확인 후 성공 처리 -> 브로커 1대
            #     장애에도 유실 없음 (로컬 RF=1에서는 리더 확인과 동일하며,
            #     프로덕션 RF=3 + min.insync.replicas=2에서 의미가 완성된다)
            #   - idempotence: 프로듀서 재시도로 인한 브로커 내 중복/순서
            #     꼬임을 제거 (컨슈머->DB 구간 중복은 event_id가 담당)
            acks="all",
            enable_idempotence=True,
            # ------------------------------------------------
            linger_ms=settings.kafka_linger_ms,
            compression_type=settings.kafka_compression_type,
            request_timeout_ms=settings.kafka_request_timeout_ms,
            value_serializer=_serialize_value,
            key_serializer=_serialize_key,
        )

        # compose의 healthcheck + depends_on을 통과했더라도
        # '브로커가 떴지만 아직 요청을 못 받는' 짧은 틈이 존재한다.
        # 그 틈에 앱이 죽지 않도록 지수 백오프로 재시도한다.
        # -> "docker compose up 한 줄로 재현"의 안정성을 코드가 보강
        retries = settings.kafka_connect_retries
        for attempt in range(1, retries + 1):
            try:
                await producer.start()
                break
            except KafkaConnectionError:
                if attempt == retries:
                    raise
                wait = min(2**attempt, 10)
                logger.warning(
                    "kafka not ready, retrying in %ds (%d/%d)", wait, attempt, retries
                )
                await asyncio.sleep(wait)

        self._producer = producer
        logger.info(
            "kafka producer started (servers=%s, topic=%s, acks=all, idempotence=True)",
            settings.kafka_bootstrap_servers,
            settings.kafka_topic,
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
        linger_ms 창 안에 모인 동시 요청들은 한 배치로 묶여 나가고,
        배치 단위 ack 한 번으로 함께 풀린다.
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