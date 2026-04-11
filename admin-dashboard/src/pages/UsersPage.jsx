import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'
import { logAudit } from '../lib/helpers'
import { useData } from '../lib/DataContext'
import ConfirmDialog from '../components/ConfirmDialog'

export default function UsersPage() {
  const { triggerRefresh, refreshKey } = useData()
  const [users, setUsers] = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [editUser, setEditUser] = useState(null)
  const [form, setForm] = useState({})
  const [saving, setSaving] = useState(false)
  const [useProfiles, setUseProfiles] = useState(true)
  const [error, setError] = useState(null)
  const [confirmAction, setConfirmAction] = useState(null)

  useEffect(() => { loadUsers() }, [refreshKey])

  const loadUsers = async () => {
    setLoading(true)
    try {
      const { data, error: err } = await supabase.from('profiles').select('*').order('created_at', { ascending: false }).limit(500)
      if (!err && data) {
        setUseProfiles(true); setUsers(data)
      } else {
        setUseProfiles(false)
        const { data: predData } = await supabase.from('predictions').select('user_id, created_at').order('created_at', { ascending: false }).limit(5000)
        if (predData) {
          const map = {}
          predData.forEach(p => {
            if (!map[p.user_id]) map[p.user_id] = { id: p.user_id, email: p.user_id, role: 'user', is_active: true, created_at: p.created_at, prediction_count: 0 }
            map[p.user_id].prediction_count++
          })
          setUsers(Object.values(map))
        }
      }
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  const openEdit = (u) => { setForm({ role: u.role || 'user', is_active: u.is_active !== false }); setEditUser(u) }

  const saveUser = async () => {
    if (!useProfiles) return setError('Requires a profiles table in Supabase.')
    const doSave = async () => {
      setSaving(true)
      const { error } = await supabase.from('profiles').update({ role: form.role, is_active: form.is_active }).eq('id', editUser.id)
      setSaving(false)
      if (!error) {
        logAudit(supabase, form.role !== editUser.role ? 'user_role_changed' : 'user_status_changed', 'user', editUser.id, { email: editUser.email, role: form.role, is_active: form.is_active })
        setEditUser(null); loadUsers(); triggerRefresh()
      } else setError('Error: ' + error.message)
    }
    if (editUser.role === 'admin' && form.role !== 'admin') {
      setConfirmAction({ title: 'Revoke Admin', message: `Remove admin privileges from ${editUser.email}?`, danger: true, confirmLabel: 'Revoke', onConfirm: () => { setConfirmAction(null); doSave() } })
    } else if (form.is_active === false && editUser.is_active !== false) {
      setConfirmAction({ title: 'Suspend User', message: `Suspend ${editUser.email}? They will no longer be able to access the app.`, danger: true, confirmLabel: 'Suspend', onConfirm: () => { setConfirmAction(null); doSave() } })
    } else {
      doSave()
    }
  }

  const filtered = users.filter(u => !search || (u.email || '').toLowerCase().includes(search.toLowerCase()))

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Users</h1>
        <p className="page-subtitle">Manage user accounts, roles and access permissions</p>
      </div>
      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><div>{error}</div></div>}
      {!useProfiles && (
        <div className="alert alert-warn">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
          <div><strong>No profiles table found.</strong> Create a <code>profiles</code> table mirroring <code>auth.users</code> for full user management.</div>
        </div>
      )}
      <div className="stats-grid" style={{ gridTemplateColumns: 'repeat(3, 1fr)', marginBottom: 16 }}>
        {[
          { label: 'Total Users', value: users.length, accent: '#16a34a' },
          { label: 'Admins', value: users.filter(u => u.role === 'admin').length, accent: '#7c3aed' },
          { label: 'Active', value: users.filter(u => u.is_active !== false).length, accent: '#0284c7' },
        ].map(s => (
          <div key={s.label} className="stat-card" style={{ padding: '14px 16px' }}>
            <div className="stat-card-accent" style={{ background: s.accent }} />
            <div className="stat-label">{s.label}</div>
            <div className="stat-value" style={{ fontSize: 24 }}>{s.value}</div>
          </div>
        ))}
      </div>
      <div className="card">
        <div className="filters" style={{ marginBottom: 16 }}>
          <input type="search" placeholder="Search by email..." value={search} onChange={e => setSearch(e.target.value)} style={{ minWidth: 260 }} />
        </div>
        {loading ? <div className="loading-spinner"><div className="spinner" /></div> : (
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>Email / User ID</th>
                  {useProfiles && <th>Role</th>}
                  <th>Status</th>
                  <th>Joined</th>
                  {!useProfiles && <th>Predictions</th>}
                  {useProfiles && <th>Actions</th>}
                </tr>
              </thead>
              <tbody>
                {filtered.map(u => (
                  <tr key={u.id}>
                    <td>
                      <div style={{ fontWeight: 500, color: '#121c28', fontSize: 13 }}>{u.email || u.id}</div>
                      {useProfiles && <div className="font-mono" style={{ color: '#94a3b8' }}>{String(u.id).slice(0, 16)}...</div>}
                    </td>
                    {useProfiles && <td><span className={`badge ${u.role === 'admin' ? 'badge-primary' : 'badge-gray'}`}>{u.role || 'user'}</span></td>}
                    <td>
                      <span className={`badge ${u.is_active !== false ? 'badge-green' : 'badge-red'}`}>
                        <span className={`status-dot ${u.is_active !== false ? 'green' : 'red'}`} />
                        {u.is_active !== false ? 'Active' : 'Suspended'}
                      </span>
                    </td>
                    <td style={{ fontSize: 12, color: '#64748b' }}>{u.created_at ? new Date(u.created_at).toLocaleDateString() : '---'}</td>
                    {!useProfiles && <td>{u.prediction_count || 0}</td>}
                    {useProfiles && <td><button className="btn btn-sm" onClick={() => openEdit(u)}>Edit</button></td>}
                  </tr>
                ))}
                {filtered.length === 0 && <tr><td colSpan={6} style={{ textAlign: 'center', color: '#94a3b8', padding: 32 }}>No users found</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {editUser && (
        <div className="modal-overlay" onClick={() => setEditUser(null)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">Edit User</span>
              <button className="modal-close" onClick={() => setEditUser(null)}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M6 18L18 6M6 6l12 12"/></svg>
              </button>
            </div>
            <div style={{ fontSize: 13, color: '#64748b', marginBottom: 16 }}>{editUser.email}</div>
            <div className="form-group">
              <label className="form-label">Role</label>
              <select className="form-input" value={form.role} onChange={e => setForm(f => ({ ...f, role: e.target.value }))}>
                <option value="user">User</option>
                <option value="admin">Admin</option>
              </select>
            </div>
            <div className="form-group" style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <input type="checkbox" id="u_active" checked={form.is_active} onChange={e => setForm(f => ({ ...f, is_active: e.target.checked }))} />
              <label htmlFor="u_active" className="form-label" style={{ marginBottom: 0 }}>Account Active</label>
            </div>
            <div className="modal-footer">
              <button className="btn" onClick={() => setEditUser(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={saveUser} disabled={saving}>{saving ? 'Saving...' : 'Save Changes'}</button>
            </div>
          </div>
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )
}
