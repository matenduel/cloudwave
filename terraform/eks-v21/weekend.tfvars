# 만들고 지우는 반복 테스트용 — 작고 싼 노드로 돌립니다.
# 환경별로 달라지는 값만 여기 둡니다. 그 외 값은 variables.tf 기본값을 그대로 씁니다.
node_instance_type = "t3.small"

# 아래는 사람마다 달라지는 값의 예시입니다(variables.tf 기본값은 바꾸지 않습니다).
# 필요할 때만 주석을 풀어 자기 값으로 채웁니다.
# public_access_cidrs = ["집/학교 공인IP/32"]  # curl ifconfig.me 로 확인
# owner               = "강사"
