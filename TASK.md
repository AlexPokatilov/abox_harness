# AIRe: Harness

### Завдання

0. Розгорнути інфру abox https://github.com/den-vasyliev/abox

1. Розгорнутися з релізу feat/llmd-embeddings

2. Додати офіційний qdrant MCP https://github.com/qdrant/mcp-server-qdrant

3. Налаштувати модель для retrivial-agent та k8s-agent (можна зробити копію з власними ключами google ai studio)

4. Додати інструменти офіційного qdrant MCP

5. Налаштувати системний промпт для використання офіційного qdrant MCP

6. Проіндексувати будь-які дані (наприклад k8s маніфести, або gitea repo homelab-k3s) з sentence-transformers/all-MiniLM-L6-v2

7. Проіндексувати ті ж самі дані з дефолтним qdrant MCP (змініть тулсет)

8. Порівняти та оцінити якість Agentic Retrieval і додати результати до ADR
