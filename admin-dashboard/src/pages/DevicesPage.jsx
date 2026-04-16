import { useState, useEffect, useRef } from 'react'
import { supabase } from '../lib/supabase'
import { logAudit, deepEqual } from '../lib/helpers'
import { useData } from '../lib/DataContext'
import ConfirmDialog from '../components/ConfirmDialog'

const STATUS_COLORS = {
  online:         { bg: '#dcfce7', text: '#16a34a' },
  assigned:       { bg: '#e0f2fe', text: '#0284c7' },
  offline:        { bg: '#fef3c7', text: '#d97706' },
  unassigned:     { bg: '#f1f5f9', text: '#64748b' },
  decommissioned: { bg: '#fee2e2', text: '#dc2626' },
}

// If a device's DB status is 'online' but last_seen_at is stale, treat it as offline on the UI.
const HEARTBEAT_TIMEOUT_MS = 10 * 60 * 1000 // 10 minutes

function getEffectiveStatus(device) {
  if (
    device.status === 'online' &&
    device.last_seen_at &&
    Date.now() - new Date(device.last_seen_at).getTime() > HEARTBEAT_TIMEOUT_MS
  ) {
    return 'offline'
  }
  return device.status
}

export default function DevicesPage() {
  const { triggerRefresh, refreshKey, leafTypeOptions } = useData()
  const [tab, setTab] = useState('fleet')
  const [devices, setDevices] = useState([])
  const [tokens, setTokens] = useState([])
  const [users, setUsers] = useState([])
  const [modelVersions, setModelVersions] = useState({}) // {leaf_type: [{version, status}]}
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [search, setSearch] = useState('')
  const [editDevice, setEditDevice] = useState(null)
  const [form, setForm] = useState({})
  const [saving, setSaving] = useState(false)
  const [formError, setFormError] = useState(null)
  const [confirmAction, setConfirmAction] = useState(null)
  const [tokenLabel, setTokenLabel] = useState('')
  const [generatedToken, setGeneratedToken] = useState('')
  const [successMsg, setSuccessMsg] = useState(null)

  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    loadData()

    // Realtime subscription: auto-refresh when devices table changes
    const channel = supabase
      .channel('devices-realtime')
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'devices',
      }, () => {
        if (mountedRef.current) loadData()
      })
      .subscribe((status) => {
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          console.warn('Devices realtime subscription failed:', status)
        }
      })

    return () => {
      mountedRef.current = false
      supabase.removeChannel(channel)
    }
  }, [refreshKey])

  // Re-render every 60s so stale heartbeat detection updates displayed statuses
  const [, setTick] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setTick(t => t + 1), 60_000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if (!successMsg) return
    const t = setTimeout(() => setSuccessMsg(null), 4000)
    return () => clearTimeout(t)
  }, [successMsg])

  const loadData = async () => {
    try {
      setLoading(true)
      setError(null)
      const [devRes, tokRes, usersRes, modelsRes] = await Promise.all([
        supabase.from('devices').select('*').order('created_at', { ascending: false }),
        supabase.from('provisioning_tokens').select('*').order('created_at', { ascending: false }),
        supabase.from('profiles').select('id, email, role'),
        supabase.from('model_registry').select('leaf_type, version, status').in('status', ['active', 'staging']),
      ])
      if (!mountedRef.current) return
      if (devRes.error) throw devRes.error
      if (tokRes.error) throw tokRes.error

      setDevices(devRes.data || [])
      setTokens(tokRes.data || [])
      setUsers(usersRes.data || [])

      // Group model versions by leaf_type, sorted newest first
      const mv = {}
      for (const m of (modelsRes.data || [])) {
        if (!mv[m.leaf_type]) mv[m.leaf_type] = []
        mv[m.leaf_type].push({ version: m.version, status: m.status })
      }
      // Sort each leaf_type's versions: newest first (semantic version descending)
      for (const lt of Object.keys(mv)) {
        mv[lt].sort((a, b) => {
          const aParts = a.version.split('.').map(Number)
          const bParts = b.version.split('.').map(Number)
          for (let i = 0; i < Math.max(aParts.length, bParts.length); i++) {
            const aVal = aParts[i] || 0
            const bVal = bParts[i] || 0
            if (bVal !== aVal) return bVal - aVal // Descending
          }
          return 0
        })
      }
      setModelVersions(mv)
    } catch (err) {
      if (mountedRef.current) setError(err.message)
    } finally {
      if (mountedRef.current) setLoading(false)
    }
  }

  const openEdit = (device) => {
    setEditDevice(device)
    const mv = device.desired_config?.model_versions || {}
    setForm({
      device_name: device.device_name || '',
      user_id: device.user_id || '',
      mode: device.desired_config?.mode || 'periodic',
      interval_seconds: device.desired_config?.interval_seconds ?? 1800,
      default_leaf_type: device.desired_config?.default_leaf_type || '',
      model_versions_entries: Object.entries(mv).map(([lt, v]) => ({ leaf_type: lt, version: v })),
    })
    setFormError(null)
  }

  const saveDevice = async () => {
    if (!editDevice) return
    setSaving(true)
    setFormError(null)

    try {
      // Convert model_versions_entries array → { leaf_type: version } object
      const parsedModelVersions = {}
      for (const entry of (form.model_versions_entries || [])) {
        if (entry.leaf_type && entry.version) {
          if (parsedModelVersions[entry.leaf_type]) {
            setFormError(`Duplicate dataset: "${entry.leaf_type}". Each dataset can only be assigned once.`)
            setSaving(false)
            return
          }
          parsedModelVersions[entry.leaf_type] = entry.version
        }
      }

      // 1. Try RPC first (restricted column update via DB function)
      const desiredConfig = {
        mode: form.mode,
        interval_seconds: Number(form.interval_seconds) || 1800,
        default_leaf_type: form.default_leaf_type || null,
        model_versions: parsedModelVersions,
      }

      const { error: rpcErr } = await supabase.rpc('update_device_config', {
        p_device_id: editDevice.id,
        p_desired_config: desiredConfig,
        p_device_name: form.device_name || null,
      })

      if (rpcErr) {
        console.warn('RPC update_device_config failed, falling back to direct update:', rpcErr.message)
        // Fallback: direct update
        const { error: updErr } = await supabase
          .from('devices')
          .update({
            device_name: form.device_name || null,
            desired_config: desiredConfig,
          })
          .eq('id', editDevice.id)
        if (updErr) throw updErr
      }

      // 2. Handle user assignment change
      const prevUserId = editDevice.user_id || null
      const newUserId = form.user_id || null

      if (prevUserId !== newUserId) {
        const statusVal = newUserId ? 'assigned' : 'unassigned'
        const { error: assignErr } = await supabase
          .from('devices')
          .update({ user_id: newUserId || null, status: statusVal })
          .eq('id', editDevice.id)
        if (assignErr) throw assignErr

        await logAudit(supabase, 'device_assign', 'device', String(editDevice.id), {
          before: { user_id: prevUserId },
          after: { user_id: newUserId },
        })
      }

      setEditDevice(null)
      setSuccessMsg(`Device "${form.device_name || editDevice.hostname}" updated.`)
      loadData()
      triggerRefresh()
    } catch (err) {
      setFormError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const decommissionDevice = async (device) => {
    try {
      const { error: err } = await supabase.from('devices').update({
        status: 'decommissioned',
        user_id: null,
      }).eq('id', device.id)
      if (err) throw err

      await logAudit(supabase, 'device_decommission', 'device', String(device.id), {
        hostname: device.hostname,
        hw_id: device.hw_id,
      })
      setSuccessMsg(`Device "${device.device_name || device.hostname}" decommissioned.`)
      loadData()
      triggerRefresh()
    } catch (err) {
      setError(err.message)
    }
  }

  const reactivateDevice = async (device) => {
    try {
      const { error: err } = await supabase.from('devices').update({
        status: 'unassigned',
      }).eq('id', device.id)
      if (err) throw err

      await logAudit(supabase, 'device_reactivate', 'device', String(device.id), {
        hostname: device.hostname,
        hw_id: device.hw_id,
      })
      setSuccessMsg(`Device "${device.device_name || device.hostname}" reactivated.`)
      loadData()
      triggerRefresh()
    } catch (err) {
      setError(err.message)
    }
  }

  const deleteDevice = async (device) => {
    try {
      const { error: err } = await supabase.from('devices').delete().eq('id', device.id)
      if (err) throw err

      await logAudit(supabase, 'device_delete', 'device', String(device.id), {
        hostname: device.hostname,
        hw_id: device.hw_id,
        device_name: device.device_name,
      })
      setSuccessMsg(`Device "${device.device_name || device.hostname}" permanently deleted.`)
      loadData()
      triggerRefresh()
    } catch (err) {
      setError(err.message)
    }
  }

  const createToken = async () => {
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')
      
      const id = crypto.randomUUID()
      const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString()
      const { error: err } = await supabase.from('provisioning_tokens').insert({
        id,
        label: tokenLabel || 'Unnamed token',
        expires_at: expiresAt,
        created_by: user.id,
      })
      if (err) throw err

      // Build the full agrikd:// token URL
      // Token format: base64url(JSON{sub_url, key, token_id, exp})
      const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
      const supabaseKey = import.meta.env.VITE_SUPABASE_ANON_KEY
      const tokenPayload = {
        sub_url: supabaseUrl,
        key: supabaseKey,
        token_id: id,
        exp: expiresAt,
      }
      const encodedPayload = btoa(JSON.stringify(tokenPayload))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') // base64url
      const fullToken = `agrikd://${encodedPayload}`

      await logAudit(supabase, 'token_create', 'provisioning_token', id, { label: tokenLabel, expires_at: expiresAt })
      setGeneratedToken(fullToken)
      setTokenLabel('')
      loadData()
      triggerRefresh()
    } catch (err) {
      setError(err.message)
    }
  }

  // Build full agrikd:// token URL from token ID
  const buildTokenUrl = (tokenId, expiresAt) => {
    const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
    const supabaseKey = import.meta.env.VITE_SUPABASE_ANON_KEY
    const tokenPayload = {
      sub_url: supabaseUrl,
      key: supabaseKey,
      token_id: tokenId,
      exp: expiresAt,
    }
    const encodedPayload = btoa(JSON.stringify(tokenPayload))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
    return `agrikd://${encodedPayload}`
  }

  const copyTokenToClipboard = async (tok) => {
    try {
      const fullToken = buildTokenUrl(tok.id, tok.expires_at)
      await navigator.clipboard.writeText(fullToken)
      setSuccessMsg(`Token copied to clipboard!`)
    } catch (err) {
      setError('Failed to copy token')
    }
  }

  const deleteToken = async (tok) => {
    try {
      const { error: err } = await supabase.from('provisioning_tokens').delete().eq('id', tok.id)
      if (err) throw err
      await logAudit(supabase, 'token_delete', 'provisioning_token', tok.id, { label: tok.label })
      setSuccessMsg('Token deleted.')
      loadData()
      triggerRefresh()
    } catch (err) {
      setError(err.message)
    }
  }

  const filteredDevices = devices.filter(d =>
    !search ||
    (d.device_name || '').toLowerCase().includes(search.toLowerCase()) ||
    (d.hostname || '').toLowerCase().includes(search.toLowerCase()) ||
    (d.hw_id || '').toLowerCase().includes(search.toLowerCase())
  )

  const statCounts = {
    total: devices.length,
    online: devices.filter(d => getEffectiveStatus(d) === 'online').length,
    assigned: devices.filter(d => ['online', 'assigned', 'offline'].includes(getEffectiveStatus(d))).length,
    unassigned: devices.filter(d => getEffectiveStatus(d) === 'unassigned').length,
  }

  if (loading) return (
    <div className="loading-spinner"><div className="spinner" /><span>Loading devices...</span></div>
  )

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Devices</h1>
        <p className="page-subtitle">Manage Jetson edge devices and provisioning tokens</p>
      </div>

      {error && (
        <div className="alert alert-error" style={{ marginBottom: 16 }}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg>
          <div style={{ flex: 1 }}>{error}</div>
          <button onClick={() => setError(null)} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: 16, padding: '0 4px' }}>×</button>
        </div>
      )}

      {successMsg && (
        <div className="alert alert-success" style={{ marginBottom: 16 }}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
          <div style={{ flex: 1 }}>{successMsg}</div>
          <button onClick={() => setSuccessMsg(null)} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: 16, padding: '0 4px' }}>×</button>
        </div>
      )}

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 20 }}>
        {['fleet', 'tokens'].map(t => (
          <button
            key={t}
            className={`btn ${tab === t ? 'btn-primary' : ''}`}
            onClick={() => setTab(t)}
            style={tab !== t ? { background: '#f1f5f9', color: '#3d4f62' } : {}}
          >
            {t === 'fleet' ? 'Device Fleet' : 'Provisioning Tokens'}
          </button>
        ))}
      </div>

      {tab === 'fleet' && (
        <>
          {/* Stats */}
          <div className="stats-grid" style={{ gridTemplateColumns: 'repeat(4, 1fr)', marginBottom: 16 }}>
            {[
              { label: 'Total Devices', value: statCounts.total, accent: '#64748b' },
              { label: 'Online', value: statCounts.online, accent: '#16a34a' },
              { label: 'Assigned', value: statCounts.assigned, accent: '#0284c7' },
              { label: 'Unassigned', value: statCounts.unassigned, accent: '#d97706' },
            ].map(s => (
              <div key={s.label} className="stat-card">
                <div className="stat-card-accent" style={{ background: s.accent }} />
                <div className="stat-label">{s.label}</div>
                <div className="stat-value">{s.value}</div>
              </div>
            ))}
          </div>

          {/* Search */}
          <div style={{ marginBottom: 16 }}>
            <input
              type="text"
              className="input"
              placeholder="Search by name, hostname, or hw_id..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              style={{ maxWidth: 360 }}
            />
          </div>

          {/* Devices table */}
          <div className="card">
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Hostname</th>
                    <th>Status</th>
                    <th>Owner</th>
                    <th>Last Seen</th>
                    <th>Config</th>
                    <th>Models</th>
                    <th style={{ width: 120 }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredDevices.map(d => {
                    const effectiveStatus = getEffectiveStatus(d)
                    const sc = STATUS_COLORS[effectiveStatus] || STATUS_COLORS.unassigned
                    const owner = users.find(u => u.id === d.user_id)
                    const synced = (() => {
                      if (!d.desired_config || !d.reported_config) return false
                      // Compare ignoring engine_status and applied_model_versions (Jetson-added fields)
                      const { engine_status, applied_model_versions, ...repCore } = d.reported_config
                      return deepEqual(d.desired_config, repCore)
                    })()
                    const hasDesired = !!d.desired_config
                    const configLabel = !hasDesired ? 'N/A' : synced ? 'Synced' : 'Pending'
                    const configColor = !hasDesired ? '#94a3b8' : synced ? '#16a34a' : '#d97706'
                    const configTitle = !hasDesired
                      ? 'No configuration set for this device'
                      : synced
                        ? 'Device has acknowledged the current configuration'
                        : 'Device has not yet applied the latest configuration changes'
                    return (
                      <tr key={d.id}>
                        <td style={{ fontWeight: 500 }}>{d.device_name || '—'}</td>
                        <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{d.hostname}</td>
                        <td>
                          <span className="badge" style={{ background: sc.bg, color: sc.text }}>{effectiveStatus}</span>
                        </td>
                        <td style={{ fontSize: 12 }}>{owner?.email || (d.user_id ? d.user_id.slice(0, 8) : '—')}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>
                          {d.last_seen_at ? new Date(d.last_seen_at).toLocaleString() : '—'}
                        </td>
                        <td>
                          <span title={configTitle} style={{ color: configColor, fontSize: 12, cursor: 'help' }}>{configLabel}</span>
                        </td>
                        <td style={{ fontSize: 11 }}>
                          {(() => {
                            const desired = d.desired_config?.model_versions || {}
                            const applied = d.reported_config?.applied_model_versions || {}
                            const es = d.reported_config?.engine_status || {}
                            const entries = Object.entries(desired)
                            if (entries.length === 0) return <span style={{ color: '#94a3b8' }}>—</span>
                            return entries.map(([lt, v]) => {
                              const appliedVer = applied[lt]
                              const isPending = !appliedVer || appliedVer !== v
                              const engineInfo = es[lt]
                              let engineLabel = ''
                              let engineColor = '#64748b'
                              if (engineInfo) {
                                if (engineInfo.status === 'building') {
                                  engineLabel = ' ⟳ building'
                                  engineColor = '#d97706'
                                } else if (engineInfo.status === 'error') {
                                  engineLabel = ' ✗ error'
                                  engineColor = '#dc2626'
                                } else if (engineInfo.status === 'downloading') {
                                  engineLabel = ' ⟳ downloading'
                                  engineColor = '#0284c7'
                                }
                              }
                              return (
                                <div key={lt} style={{ lineHeight: 1.4 }}>
                                  <strong>{lt}</strong>: {v}
                                  {isPending && !engineLabel && <span style={{ color: '#d97706', fontSize: 10 }}> (pending)</span>}
                                  {engineLabel && <span style={{ color: engineColor, fontSize: 10 }}>{engineLabel}</span>}
                                </div>
                              )
                            })
                          })()}
                        </td>
                        <td>
                          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                            <button className="btn btn-sm" onClick={() => openEdit(d)}>Edit</button>
                            {d.status !== 'decommissioned' && (
                              <button
                                className="btn btn-sm"
                                style={{ background: '#fee2e2', color: '#dc2626', border: '1px solid #fecaca' }}
                                onClick={() => setConfirmAction({
                                  title: 'Decommission Device',
                                  message: `Are you sure you want to decommission "${d.device_name || d.hostname}"? This will unassign the device and mark it as decommissioned.`,
                                  danger: true,
                                  confirmLabel: 'Decommission',
                                  onConfirm: () => { setConfirmAction(null); decommissionDevice(d) },
                                })}
                              >Decom</button>
                            )}
                            {d.status === 'decommissioned' && (
                              <>
                                <button
                                  className="btn btn-sm"
                                  style={{ background: '#dcfce7', color: '#16a34a', border: '1px solid #bbf7d0' }}
                                  onClick={() => setConfirmAction({
                                    title: 'Reactivate Device',
                                    message: `Reactivate "${d.device_name || d.hostname}"? It will be set to unassigned status.`,
                                    danger: false,
                                    confirmLabel: 'Reactivate',
                                    onConfirm: () => { setConfirmAction(null); reactivateDevice(d) },
                                  })}
                                >Activate</button>
                                <button
                                  className="btn btn-sm"
                                  style={{ background: '#fee2e2', color: '#dc2626', border: '1px solid #fecaca' }}
                                  onClick={() => setConfirmAction({
                                    title: 'Delete Device Permanently',
                                    message: `Permanently delete "${d.device_name || d.hostname}"? This action cannot be undone. All device history and predictions will be lost.`,
                                    danger: true,
                                    confirmLabel: 'Delete Forever',
                                    onConfirm: () => { setConfirmAction(null); deleteDevice(d) },
                                  })}
                                >Delete</button>
                              </>
                            )}
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                  {filteredDevices.length === 0 && (
                    <tr><td colSpan={8} style={{ textAlign: 'center', color: '#94a3b8', padding: 32 }}>No devices found</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {tab === 'tokens' && (
        <>
          {/* Create Token */}
          <div className="card" style={{ marginBottom: 20, padding: 20 }}>
            <h3 style={{ margin: '0 0 12px' }}>Create Provisioning Token</h3>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <input
                type="text"
                className="input"
                placeholder="Label (e.g., Lab Room A)"
                value={tokenLabel}
                onChange={e => setTokenLabel(e.target.value)}
                style={{ maxWidth: 280 }}
              />
              <button className="btn btn-primary" onClick={createToken}>Generate Token</button>
            </div>
            {generatedToken && (
              <div className="alert alert-success" style={{ marginTop: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div>
                  <strong>Token created!</strong>
                  <div style={{ fontFamily: 'monospace', fontSize: 13, marginTop: 4, wordBreak: 'break-all' }}>{generatedToken}</div>
                  <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>Copy this token — it won't be shown again. Expires in 24 hours.</div>
                </div>
              </div>
            )}
          </div>

          {/* Tokens table */}
          <div className="card">
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Token ID</th>
                    <th>Label</th>
                    <th>Created</th>
                    <th>Expires</th>
                    <th>Status</th>
                    <th>Used By</th>
                    <th style={{ width: 80 }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {tokens.map(tok => {
                    const isUsed = !!tok.used_at
                    const isExpired = !isUsed && new Date(tok.expires_at) < new Date()
                    const statusLabel = isUsed ? 'Used' : isExpired ? 'Expired' : 'Available'
                    const statusColor = isUsed ? '#16a34a' : isExpired ? '#dc2626' : '#0284c7'
                    return (
                      <tr key={tok.id}>
                        <td style={{ fontFamily: 'monospace', fontSize: 11, maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis' }}>{tok.id}</td>
                        <td>{tok.label || '—'}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{new Date(tok.created_at).toLocaleString()}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{new Date(tok.expires_at).toLocaleString()}</td>
                        <td>
                          <span className="badge" style={{ background: isUsed ? '#dcfce7' : isExpired ? '#fee2e2' : '#e0f2fe', color: statusColor }}>{statusLabel}</span>
                        </td>
                        <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{tok.used_by_hw_id || '—'}</td>
                        <td style={{ display: 'flex', gap: 4 }}>
                          {!isUsed && !isExpired && (
                            <button
                              className="btn btn-sm"
                              style={{ background: '#e0f2fe', color: '#0284c7', border: '1px solid #bae6fd' }}
                              onClick={() => copyTokenToClipboard(tok)}
                              title="Copy full token to clipboard"
                            >Copy</button>
                          )}
                          <button
                            className="btn btn-sm"
                            style={{ background: '#fee2e2', color: '#dc2626', border: '1px solid #fecaca' }}
                            onClick={() => setConfirmAction({
                              title: 'Delete Token',
                              message: isUsed
                                ? `Delete used token "${tok.label || tok.id.slice(0,8)}"? The device that used this token will NOT be affected.`
                                : `Delete token "${tok.label || tok.id.slice(0,8)}"? This cannot be undone.`,
                              danger: true,
                              confirmLabel: 'Delete',
                              onConfirm: () => { setConfirmAction(null); deleteToken(tok) },
                            })}
                          >Del</button>
                        </td>
                      </tr>
                    )
                  })}
                  {tokens.length === 0 && (
                    <tr><td colSpan={7} style={{ textAlign: 'center', color: '#94a3b8', padding: 32 }}>No provisioning tokens</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {/* Edit Device Modal */}
      {editDevice && (
        <div className="modal-overlay" onClick={() => setEditDevice(null)}>
          <div className="modal" onClick={e => e.stopPropagation()} style={{ maxWidth: 520 }}>
            <h3 style={{ margin: '0 0 16px' }}>Edit Device — {editDevice.hostname}</h3>
            {formError && (
              <div className="alert alert-error" style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg>
                <div style={{ flex: 1 }}>{formError}</div>
              </div>
            )}
            <div className="form-group">
              <label className="form-label">Device Name</label>
              <input className="input" value={form.device_name} onChange={e => setForm(f => ({ ...f, device_name: e.target.value }))} />
            </div>
            <div className="form-group">
              <label className="form-label">Assign to User</label>
              <select className="input" value={form.user_id} onChange={e => setForm(f => ({ ...f, user_id: e.target.value }))}>
                <option value="">— Unassigned —</option>
                {users.map(u => (
                  <option key={u.id} value={u.id}>{u.email} ({u.role})</option>
                ))}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">Operating Mode</label>
              <select className="input" value={form.mode} onChange={e => setForm(f => ({ ...f, mode: e.target.value }))}>
                <option value="periodic">Periodic</option>
                <option value="manual">Manual</option>
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">Capture Interval (seconds)</label>
              <input className="input" type="number" min={60} max={86400} value={form.interval_seconds} onChange={e => setForm(f => ({ ...f, interval_seconds: e.target.value }))} />
            </div>
            <div className="form-group">
              <label className="form-label">Default Leaf Type</label>
              <select className="input" value={form.default_leaf_type} onChange={e => setForm(f => ({ ...f, default_leaf_type: e.target.value }))}>
                <option value="">— None —</option>
                {(leafTypeOptions || []).map(lt => (
                  <option key={lt} value={lt}>{lt}</option>
                ))}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">Assigned Models</label>
              {(form.model_versions_entries || []).length === 0 && (
                <div style={{ fontSize: 13, color: '#94a3b8', marginBottom: 8 }}>
                  No models assigned. Click "Add Model" to assign a dataset version.
                </div>
              )}
              {(form.model_versions_entries || []).map((entry, idx) => {
                const availableLeafTypes = Object.keys(modelVersions).filter(lt =>
                  lt === entry.leaf_type || !(form.model_versions_entries || []).some((e, i) => i !== idx && e.leaf_type === lt)
                )
                const versionsForLeaf = modelVersions[entry.leaf_type] || []
                return (
                  <div key={idx} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 8 }}>
                    <select
                      className="input"
                      style={{ flex: 1 }}
                      value={entry.leaf_type}
                      onChange={e => {
                        const newEntries = [...form.model_versions_entries]
                        const newLeaf = e.target.value
                        const newVersions = modelVersions[newLeaf] || []
                        const activeVer = newVersions.find(v => v.status === 'active')
                        newEntries[idx] = { leaf_type: newLeaf, version: activeVer?.version || newVersions[0]?.version || '' }
                        setForm(f => ({ ...f, model_versions_entries: newEntries }))
                      }}
                    >
                      <option value="">— Select Dataset —</option>
                      {availableLeafTypes.map(lt => (
                        <option key={lt} value={lt}>{lt}</option>
                      ))}
                    </select>
                    <select
                      className="input"
                      style={{ flex: 1 }}
                      value={entry.version}
                      onChange={e => {
                        const newEntries = [...form.model_versions_entries]
                        newEntries[idx] = { ...newEntries[idx], version: e.target.value }
                        setForm(f => ({ ...f, model_versions_entries: newEntries }))
                      }}
                      disabled={!entry.leaf_type}
                    >
                      <option value="">— Select Version —</option>
                      {versionsForLeaf.map(v => (
                        <option key={v.version} value={v.version}>
                          {v.version} ({v.status})
                        </option>
                      ))}
                    </select>
                    <button
                      type="button"
                      className="btn"
                      style={{ padding: '6px 10px', color: '#dc2626', minWidth: 'auto' }}
                      title="Remove"
                      onClick={() => {
                        const newEntries = form.model_versions_entries.filter((_, i) => i !== idx)
                        setForm(f => ({ ...f, model_versions_entries: newEntries }))
                      }}
                    >
                      ✕
                    </button>
                  </div>
                )
              })}
              {Object.keys(modelVersions).length > (form.model_versions_entries || []).length && (
                <button
                  type="button"
                  className="btn"
                  style={{ fontSize: 13, padding: '4px 12px' }}
                  onClick={() => {
                    const usedLeafTypes = new Set((form.model_versions_entries || []).map(e => e.leaf_type))
                    const nextLeaf = Object.keys(modelVersions).find(lt => !usedLeafTypes.has(lt)) || ''
                    const nextVersions = modelVersions[nextLeaf] || []
                    const activeVer = nextVersions.find(v => v.status === 'active')
                    setForm(f => ({
                      ...f,
                      model_versions_entries: [
                        ...(f.model_versions_entries || []),
                        { leaf_type: nextLeaf, version: activeVer?.version || nextVersions[0]?.version || '' },
                      ],
                    }))
                  }}
                >
                  + Add Model
                </button>
              )}
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 16 }}>
              <button className="btn" onClick={() => setEditDevice(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={saveDevice} disabled={saving}>
                {saving ? 'Saving...' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Confirm dialog */}
      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )
}