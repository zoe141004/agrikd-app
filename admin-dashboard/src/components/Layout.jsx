import { NavLink } from 'react-router-dom'

export default function Layout({ children, onSignOut }) {
  return (
    <div className="layout">
      <nav className="sidebar">
        <h2>AgriKD Admin</h2>
        <NavLink to="/" end className={({ isActive }) => isActive ? 'active' : ''}>
          Dashboard
        </NavLink>
        <NavLink to="/predictions" className={({ isActive }) => isActive ? 'active' : ''}>
          Predictions
        </NavLink>
        <NavLink to="/models" className={({ isActive }) => isActive ? 'active' : ''}>
          Models
        </NavLink>
        <a href="#" onClick={(e) => { e.preventDefault(); onSignOut() }} style={{ marginTop: 'auto', position: 'absolute', bottom: 20, left: 0, right: 0 }}>
          Sign Out
        </a>
      </nav>
      <main className="main">{children}</main>
    </div>
  )
}
