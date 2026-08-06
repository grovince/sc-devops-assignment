from datetime import datetime
from typing import Any
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field


class LogEvent(BaseModel):
    """인게임 로그 이벤트.

    설계 원칙: 수집 계층은 스키마에 최소한으로만 관여한다.

    게임 로그는 타이틀별로, 업데이트마다 필드가 바뀐다.
    수집 API가 전체 필드를 검증하면 새 이벤트 타입이 추가될 때마다
    로그 수집 서버를 재배포해야 하는 결합이 생긴다.

    따라서 파이프라인 동작에 반드시 필요한 필드만 필수로 두고,
    나머지는 payload로 자유롭게 통과시킨다.
    스키마 강제는 컨슈머/분석 계층의 책임으로 미룬다.
    """

    model_config = ConfigDict(extra="allow")

    # 멱등 적재 키. Kafka 전송 '이전에' 값이 확정되므로,
    # 같은 Kafka 레코드가 재소비되어도 event_id가 동일하다.
    # -> 컨슈머가 MongoDB unique index로 중복 insert를 걸러낼 수 있다.
    #
    # 클라이언트가 직접 보내면 그 값을 쓴다(재시도까지 포함한 end-to-end 멱등).
    # 없으면 API가 생성한다(컨슈머->DB 구간의 멱등만 보장).
    event_id: str = Field(default_factory=lambda: str(uuid4()), max_length=64)

    # 파티션 키. 유저 단위 이벤트 순서 보장에 사용
    user_id: str = Field(..., min_length=1, max_length=128)
    # 컨슈머의 라우팅/분류 기준
    event_type: str = Field(..., min_length=1, max_length=128)
    # 클라이언트 발생 시각 (서버 수신 시각과 구분)
    timestamp: datetime

    payload: dict[str, Any] = Field(default_factory=dict)


class IngestResponse(BaseModel):
    result: str = "ok"
    # 클라이언트가 자신의 로그를 추적/재시도할 때 쓰는 식별자
    event_id: str
    topic: str
    partition: int
    offset: int