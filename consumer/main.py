import asyncio
import os
from datetime import datetime, timezone
from pathlib import Path

from aiokafka import AIOKafkaConsumer

SINK_DIR = Path(os.getenv("SINK_DIR", "/data/logs"))


async def run():
    consumer = AIOKafkaConsumer(
        os.getenv("KAFKA_TOPIC", "game-logs"),
        bootstrap_servers=os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092"),
        group_id="file-sink",
        # 자동 커밋을 끈다. '소비했다'는 이유만으로 오프셋이 올라간 직후
        # 프로세스가 죽으면 그 구간은 파일에 쓰이지도, 재소비되지도 않는다.
        # [파일 write -> commit] 순서를 지켜야 at-least-once가 성립한다.
        enable_auto_commit=False,
        # 컨슈머보다 프로듀서가 먼저 뜬 경우, 이미 쌓인 로그부터 소비
        auto_offset_reset="earliest",
    )
    await consumer.start()
    SINK_DIR.mkdir(parents=True, exist_ok=True)

    try:
        while True:
            # 최대 500건 또는 1초 중 먼저 도달하는 쪽에서 배치를 끊는다.
            # (Firehose의 buffer size / buffer interval과 같은 역할)
            batches = await consumer.getmany(timeout_ms=1000, max_records=500)
            records = [r.value for rs in batches.values() for r in rs]
            if not records:
                continue

            # UTC 일자별 파일. 프로덕션에서 S3 프리픽스로 날짜를 나누는 것과 동일.
            # 'ab' = append 모드 -> 컨테이너가 재시작해도 덮어쓰지 않는다.
            day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            with open(SINK_DIR / f"game-logs-{day}.jsonl", "ab") as f:
                for value in records:
                    f.write(value + b"\n")
            # with 블록을 나오며 파일이 닫히고 flush된 '뒤에' 커밋한다.
            await consumer.commit()
            print(f"sunk {len(records)} records", flush=True)
    finally:
        await consumer.stop()


asyncio.run(run())