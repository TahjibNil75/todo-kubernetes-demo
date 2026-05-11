import { useState, useEffect } from 'react'

const API = import.meta.env.VITE_API_URL || '/api'

export default function App() {
  const [todos, setTodos] = useState([])
  const [input, setInput] = useState('')

  useEffect(() => {
    fetch(`${API}/todos`)
      .then(r => r.json())
      .then(setTodos)
  }, [])

  const addTodo = async (e) => {
    e.preventDefault()
    if (!input.trim()) return
    const res = await fetch(`${API}/todos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: input.trim() }),
    })
    const todo = await res.json()
    setTodos(prev => [...prev, todo])
    setInput('')
  }

  const toggleTodo = async (id) => {
    const res = await fetch(`${API}/todos/${id}`, { method: 'PATCH' })
    const updated = await res.json()
    setTodos(prev => prev.map(t => t.id === id ? updated : t))
  }

  const deleteTodo = async (id) => {
    await fetch(`${API}/todos/${id}`, { method: 'DELETE' })
    setTodos(prev => prev.filter(t => t.id !== id))
  }

  const remaining = todos.filter(t => !t.completed).length

  return (
    <div className="container">
      <h1>Todo App</h1>
      <p className="subtitle">{remaining} task{remaining !== 1 ? 's' : ''} remaining</p>

      <form onSubmit={addTodo} className="form">
        <input
          type="text"
          value={input}
          onChange={e => setInput(e.target.value)}
          placeholder="What needs to be done?"
          className="input"
        />
        <button type="submit" className="btn-add">Add</button>
      </form>

      <ul className="todo-list">
        {todos.length === 0 && (
          <li className="empty">No todos yet. Add one above!</li>
        )}
        {todos.map(todo => (
          <li key={todo.id} className={`todo-item ${todo.completed ? 'completed' : ''}`}>
            <input
              type="checkbox"
              checked={todo.completed}
              onChange={() => toggleTodo(todo.id)}
              className="checkbox"
            />
            <span className="title">{todo.title}</span>
            <button onClick={() => deleteTodo(todo.id)} className="btn-delete">✕</button>
          </li>
        ))}
      </ul>
    </div>
  )
}
