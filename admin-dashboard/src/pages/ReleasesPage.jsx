import { useState, useEffect } from 'react'
import { getGitHubConfig, triggerGitHubWorkflow } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'

const TABS = ['Commits', 'Pull Requests', 'Releases']

export default function ReleasesPage() {
  const [tab, setTab] = useState('Commits')
  const [commits, setCommits] = useState([])
  const [prs, setPrs] = useState([])
  const [releases, setReleases] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [confirmAction, setConfirmAction] = useState(null)
  const [actionMsg, setActionMsg] = useState(null)
  const [versionTag, setVersionTag] = useState('')
  const [creating, setCreating] = useState(false)

  const { ghToken, ghOwner, ghRepo } = getGitHubConfig()
  const configured = !!(ghToken && ghOwner && ghRepo)

  useEffect(() => { if (configured) loadData(); else setLoading(false) }, [])

  const ghFetch = async (path) => {
    const res = await fetch(`https://api.github.com/repos/${ghOwner}/${ghRepo}${path}`, {
      headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json' },
    })
    if (!res.ok) throw new Error(`GitHub API error: ${res.status}`)
    return res.json()
  }

  const loadData = async () => {
    setLoading(true)
    setError(null)
    try {
      const [c, p, r] = await Promise.all([
        ghFetch('/commits?per_page=15'),
        ghFetch('/pulls?state=open&per_page=10'),
        ghFetch('/releases?per_page=10'),
      ])
      setCommits(c || [])
      setPrs(p || [])
      setReleases(r || [])
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  const mergePR = (pr) => {
    setConfirmAction({
      title: 'Merge Pull Request',
      message: `Merge PR #${pr.number} "${pr.title}" into ${pr.base?.ref}? This cannot be undone.`,
      danger: false,
      confirmLabel: 'Merge',
      onConfirm: async () => {
        setConfirmAction(null)
        try {
          const res = await fetch(`https://api.github.com/repos/${ghOwner}/${ghRepo}/pulls/${pr.number}/merge`, {
            method: 'PUT',
            headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
            body: JSON.stringify({ merge_method: 'squash' }),
          })
          if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.message || `HTTP ${res.status}`) }
          setActionMsg({ type: 'success', text: `PR #${pr.number} merged successfully.` })
          loadData()
        } catch (err) { setActionMsg({ type: 'error', text: err.message }) }
      },
    })
  }

  const createRelease = async () => {
    if (!versionTag) { setActionMsg({ type: 'error', text: 'Enter a version tag (e.g. v1.2.0).' }); return }
    setCreating(true)
    setActionMsg(null)
    try {
      const res = await fetch(`https://api.github.com/repos/${ghOwner}/${ghRepo}/releases`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
        body: JSON.stringify({ tag_name: versionTag, name: versionTag, generate_release_notes: true }),
      })
      if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.message || `HTTP ${res.status}`) }
      setActionMsg({ type: 'success', text: `Release ${versionTag} created successfully.` })
      setVersionTag('')
      loadData()
    } catch (err) { setActionMsg({ type: 'error', text: err.message }) }
    setCreating(false)
  }

  const triggerDeploy = () => {
    setConfirmAction({
      title: 'Trigger Deployment',
      message: 'Dispatch deploy.yml workflow? This will trigger a production deployment.',
      danger: false,
      confirmLabel: 'Deploy',
      onConfirm: async () => {
        setConfirmAction(null)
        try {
          await triggerGitHubWorkflow('deploy.yml')
          setActionMsg({ type: 'success', text: 'Deploy workflow dispatched. Check GitHub Actions for progress.' })
        } catch (err) { setActionMsg({ type: 'error', text: err.message }) }
      },
    })
  }

  if (!configured) return (
    <>
      <div className="page-header">
        <h1 className="page-title">Releases</h1>
        <p className="page-subtitle">Manage releases, pull requests, and deployments</p>
      </div>
      <div className="alert alert-warn">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
        <div>GitHub not configured. Go to <strong>Settings &rarr; Integrations</strong> to add your GitHub token, owner, and repo.</div>
      </div>
    </>
  )

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Loading releases...</span></div>

  return (
    <>
      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><div>{error}</div></div>}
      {actionMsg && <div className={`alert ${actionMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg><div>{actionMsg.text}</div></div>}

      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <h1 className="page-title">Releases</h1>
          <p className="page-subtitle">Commits, pull requests, and release management for {ghOwner}/{ghRepo}</p>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn" onClick={loadData}>Refresh</button>
          <button className="btn btn-primary" onClick={triggerDeploy}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>
            Trigger Deploy
          </button>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {TABS.map(t => (
          <button key={t} onClick={() => setTab(t)} style={{ padding: '10px 18px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: tab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${tab === t ? '#16a34a' : 'transparent'}`, fontFamily: 'inherit' }}>
            {t} {t === 'Pull Requests' && prs.length > 0 ? `(${prs.length})` : ''}
          </button>
        ))}
      </div>

      {/* ── Commits Tab ── */}
      {tab === 'Commits' && (
        <div className="card">
          <div className="card-header"><div><div className="card-label">History</div><div className="card-title">Recent Commits</div></div></div>
          <div className="table-wrapper">
            <table>
              <thead><tr><th>SHA</th><th>Message</th><th>Author</th><th>Date</th></tr></thead>
              <tbody>
                {commits.map(c => (
                  <tr key={c.sha}>
                    <td><a href={c.html_url} target="_blank" rel="noopener noreferrer" className="font-mono" style={{ color: '#16a34a', fontSize: 12 }}>{c.sha.slice(0, 7)}</a></td>
                    <td style={{ maxWidth: 320, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{c.commit?.message?.split('\n')[0]}</td>
                    <td style={{ fontSize: 12, color: '#64748b' }}>{c.commit?.author?.name || c.author?.login}</td>
                    <td style={{ fontSize: 12, color: '#94a3b8' }}>{new Date(c.commit?.author?.date).toLocaleDateString()}</td>
                  </tr>
                ))}
                {commits.length === 0 && <tr><td colSpan={4} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No commits found</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* ── Pull Requests Tab ── */}
      {tab === 'Pull Requests' && (
        <div className="card">
          <div className="card-header"><div><div className="card-label">Open</div><div className="card-title">Pull Requests ({prs.length})</div></div></div>
          {prs.length > 0 ? (
            <div className="table-wrapper">
              <table>
                <thead><tr><th>#</th><th>Title</th><th>Author</th><th>Base</th><th>Created</th><th>Actions</th></tr></thead>
                <tbody>
                  {prs.map(pr => (
                    <tr key={pr.id}>
                      <td><a href={pr.html_url} target="_blank" rel="noopener noreferrer" style={{ color: '#16a34a', fontWeight: 600 }}>#{pr.number}</a></td>
                      <td style={{ maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{pr.title}</td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>{pr.user?.login}</td>
                      <td><span className="badge badge-gray">{pr.base?.ref}</span></td>
                      <td style={{ fontSize: 12, color: '#94a3b8' }}>{new Date(pr.created_at).toLocaleDateString()}</td>
                      <td>
                        <button className="btn btn-sm btn-primary" onClick={() => mergePR(pr)}>Merge</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="empty-state"><p>No open pull requests.</p></div>
          )}
        </div>
      )}

      {/* ── Releases Tab ── */}
      {tab === 'Releases' && (
        <>
          <div className="card" style={{ marginBottom: 20 }}>
            <div className="card-header"><div><div className="card-label">Create</div><div className="card-title">New Release</div></div></div>
            <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
              <div className="form-group" style={{ flex: 1, marginBottom: 0 }}>
                <label className="form-label">Version Tag</label>
                <input className="form-input" value={versionTag} onChange={e => setVersionTag(e.target.value)} placeholder="v1.2.0" />
              </div>
              <button className="btn btn-primary" onClick={createRelease} disabled={creating || !versionTag} style={{ height: 38 }}>
                {creating ? 'Creating...' : 'Create Release'}
              </button>
            </div>
          </div>

          <div className="card">
            <div className="card-header"><div><div className="card-label">History</div><div className="card-title">Release History</div></div></div>
            {releases.length > 0 ? (
              <div className="table-wrapper">
                <table>
                  <thead><tr><th>Tag</th><th>Name</th><th>Author</th><th>Date</th><th>Link</th></tr></thead>
                  <tbody>
                    {releases.map(r => (
                      <tr key={r.id}>
                        <td><span className="badge badge-primary">{r.tag_name}</span></td>
                        <td>{r.name || r.tag_name}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{r.author?.login}</td>
                        <td style={{ fontSize: 12, color: '#94a3b8' }}>{new Date(r.published_at || r.created_at).toLocaleDateString()}</td>
                        <td><a href={r.html_url} target="_blank" rel="noopener noreferrer" className="btn btn-sm">View</a></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="empty-state"><p>No releases yet. Create one above.</p></div>
            )}
          </div>
        </>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )
}
