# Todo App — Run Locally

A simple Todo application with a **React** frontend and **FastAPI** backend.

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/)
- Or, for running without Docker: **Node.js 20+** and **Python 3.12+**

---

## Run with Docker (recommended)

```bash
# From the project root
docker compose up --build
```

| Service  | URL                          |
|----------|------------------------------|
| Frontend | http://localhost             |
| Backend  | http://localhost:8000        |
| API Docs | http://localhost:8000/docs   |

To stop:

```bash
docker compose down
```

---

## Run without Docker

### 1. Backend

```bash
cd backend

python -m venv venv
source venv/bin/activate        # Windows: venv\Scripts\activate

pip install -r requirements.txt

uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Backend is now running at `http://localhost:8000`.

### 2. Frontend

Open a new terminal:

```bash
cd frontend

npm install

npm run dev
```

Frontend is now running at `http://localhost:5173`.

---

## API Endpoints

### Health check

| Method | Endpoint | Description        |
|--------|----------|--------------------|
| GET    | `/`      | API status check   |

**Response:**
```json
{
  "status": "ok",
  "message": "Todo API is running"
}
```

---

### Todos

#### Get all todos

```
GET /todos
```

**Response:**
```json
[
  {
    "id": "d290f1ee-6c54-4b01-90e6-d701748f0851",
    "title": "Buy groceries",
    "completed": false
  }
]
```

---

#### Create a todo

```
POST /todos
Content-Type: application/json
```

**Request body:**
```json
{
  "title": "Buy groceries"
}
```

**Response** `201 Created`:
```json
{
  "id": "d290f1ee-6c54-4b01-90e6-d701748f0851",
  "title": "Buy groceries",
  "completed": false
}
```

---

#### Toggle a todo (complete / uncomplete)

```
PATCH /todos/{id}
```

**Response:**
```json
{
  "id": "d290f1ee-6c54-4b01-90e6-d701748f0851",
  "title": "Buy groceries",
  "completed": true
}
```

---

#### Delete a todo

```
DELETE /todos/{id}
```

**Response:** `204 No Content`

---

## Project Structure

```
todo-kubernetes-demo/
├── backend/
│   ├── main.py             # FastAPI application
│   ├── requirements.txt    # Python dependencies
│   └── Dockerfile
├── frontend/
│   ├── src/
│   │   ├── App.jsx         # Main React component
│   │   ├── main.jsx        # Entry point
│   │   └── index.css       # Styles
│   ├── index.html
│   ├── package.json
│   ├── vite.config.js
│   ├── nginx.conf          # Nginx config for production
│   └── Dockerfile
├── doc/
│   └── README.md           # This file
└── docker-compose.yml
```

---

## Notes

- Todo data is stored **in memory** — it resets when the backend restarts.
- The frontend communicates with the backend via the `VITE_API_URL` environment variable (defaults to `http://localhost:8000`).
