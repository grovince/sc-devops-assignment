from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """환경변수 기반 설정.

    docker-compose의 environment 값이 그대로 주입된다.
    (예: KAFKA_BOOTSTRAP_SERVERS=kafka:9092)

    주의: acks / enable_idempotence는 여기에 없다.
    '유실 없이'라는 요구를 만족시키는 설계 결정이므로
    설정으로 열어두지 않고 producer.py에 고정했다.
    (enable_idempotence=True는 acks="all"을 강제하는 세트 옵션이라,
    둘을 독립 설정으로 두면 서로 모순된 값이 주입될 수 있다.)
    """

    app_env: str = "local"

    kafka_bootstrap_servers: str = "kafka:9092"
    kafka_topic: str = "game-logs"

    # 배칭 대기 시간(ms). 이 시간 창 안에 도착한 요청들의 레코드가
    # 하나의 배치로 묶여 전송된다. 개별 응답에 최대 5ms를 얹는 대신
    # acks=all 환경에서도 높은 처리량을 확보한다.
    kafka_linger_ms: int = 5

    # 압축: lz4는 gzip 대비 압축 속도가 수 배 빨라 API 컨테이너의
    # CPU를 압축에 뺏기지 않는다.
    # (aiokafka 0.14는 압축 백엔드로 cramjam을 사용한다
    #  -> requirements의 aiokafka[lz4] extras가 이를 끌어온다)
    kafka_compression_type: str = "lz4"

    kafka_request_timeout_ms: int = 10_000

    # 기동 시 브로커 연결 재시도 횟수 (지수 백오프)
    kafka_connect_retries: int = 10


settings = Settings()