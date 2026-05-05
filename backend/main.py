from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
import uuid

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

class TodoCreate(BaseModel):
    title: str

class Todo(BaseModel):
    id: str
    title: str
    completed: bool

todos: List[Todo] = []


@app.get("/health")
def root():
    return {"status": "ok", "message": "Todo API is running"}


@app.get("/todos", response_model=List[Todo])
def get_todos():
    return todos


@app.post("/todos", response_model=Todo, status_code=201)
def create_todo(payload: TodoCreate):
    todo = Todo(id=str(uuid.uuid4()), title=payload.title, completed=False)
    todos.append(todo)
    return todo


@app.patch("/todos/{todo_id}", response_model=Todo)
def toggle_todo(todo_id: str):
    for todo in todos:
        if todo.id == todo_id:
            todo.completed = not todo.completed
            return todo
    raise HTTPException(status_code=404, detail="Todo not found")


@app.delete("/todos/{todo_id}", status_code=204)
def delete_todo(todo_id: str):
    for i, todo in enumerate(todos):
        if todo.id == todo_id:
            todos.pop(i)
            return
    raise HTTPException(status_code=404, detail="Todo not found")
