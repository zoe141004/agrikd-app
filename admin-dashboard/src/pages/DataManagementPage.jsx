import { useState, useEffect, useRef } from 'react'
import { supabase } from '../lib/supabase'
import { downloadFile, formatBytes, triggerGitHubWorkflow, getGitHubWorkflowRuns, getGitHubConfig } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'

const DTABS = ['Overview', 'Upload Dataset', 'Import CSV', 'DVC Sync', 'Export', 'Storage Files']

export default function DataManagementPage() {
  const [dtab, setDtab] = useState('Overview')
  const [stats, setStats] = useState({ total: 0 })
  const [quality, setQuality] = useState([])
  const [loading, setLoading] = useState(true)
  const [leafOptions, setLeafOptions] = useState([])

  // DVC state
  const [dvcLog, setDvcLog] = useState([])
  const [dvcRunning, setDvcRunning] = useState(false)
  const [dvcRuns, setDvcRuns] = useState(null)
  const [dvcPullLeaf, setDvcPullLeaf] = useState('')
  const [dvcDatasets, setDvcDatasets] = useState([])
  const [dvcDatasetsLoading, setDvcDatasetsLoading] = useState(false)

  // Dataset upload state — Method A (predictions)
  const [dsLeafType, setDsLeafType] = useState('')
  const [dsConfThreshold, setDsConfThreshold] = useState(0.8)
  const [dsPredPreview, setDsPredPreview] = useState(null)
  const [dsUploading, setDsUploading] = useState(false)
  const [dsMsg, setDsMsg] = useState(null)

  // Dataset upload state — Method B (Google Drive ZIP)
  const [dsGdriveUrl, setDsGdriveUrl] = useState('')
  const [dsGdriveName, setDsGdriveName] = useState('')
  const [dsGdriveLeaf, setDsGdriveLeaf] = useState('')

  // CSV import state
  const [csvFile, setCsvFile] = useState(null)
  const [csvParsed, setCsvParsed] = useState(null)
  const [csvImporting, setCsvImporting] = useState(false)
  const [csvProgress, setCsvProgress] = useState(0)
  const [csvMsg, setCsvMsg] = useState(null)
  const csvRef = useRef()

  // Storage Files state
  const [storedFiles, setStoredFiles] = useState([])
  const [storageLoading, setStorageLoading] = useState(false)
  const [confirmAction, setConfirmAction] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => { loadData() }, [])

  const loadData = async () => {
    setLoading(true)
    setError(null)
    try {
    const [{ data: rpcStats }, { data: leafTypeOpts }] = await Promise.all([
      supabase.rpc('get_dashboard_stats', { p_leaf_type: null }),
      supabase.rpc('get_leaf_type_options'),
    ])
    const s = rpcStats || {}
    setStats({ total: s.total || 0 })
    const leafTypes = (leafTypeOpts || []).map(r => r.leaf_type).filter(Boolean)
    setLeafOptions(leafTypes)

    // Get per-leaf-type quality via individual RPC calls
    const qualityResults = await Promise.all(
      leafTypes.map(async lt => {
        const { data: ltStats } = await supabase.rpc('get_dashboard_stats', { p_leaf_type: lt })
        const ls = ltStats || {}
        return {
          name: lt,
          total: ls.total || 0,
          highConf: ls.total ? ((ls.high_confidence_count || 0) / ls.total * 100).toFixed(0) : '0',
        }
      })
    )
    setQuality(qualityResults)
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  // ── DVC via GitHub Actions ────────────────────────────────────────────────
  const runDvc = async (op, leafType = '') => {
    setDvcRunning(true); setDvcLog([])
    const ts = () => new Date().toLocaleTimeString()
    const { ghToken } = getGitHubConfig()
    try {
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations to add your token.')
      const inputs = leafType ? { leaf_type: leafType } : {}
      const suffix = leafType ? ` (${leafType})` : ' (all)'
      setDvcLog(l => [...l, `[${ts()}] Triggering DVC ${op}${suffix} via GitHub Actions…`])
      const workflow = op === 'push' ? 'dvc-push.yml' : 'dvc-pull.yml'
      await triggerGitHubWorkflow(workflow, inputs)
      setDvcLog(l => [...l, `[${ts()}] Workflow dispatched. Checking status…`])
      await new Promise(r => setTimeout(r, 3000))
      const runs = await getGitHubWorkflowRuns(workflow)
      setDvcRuns(runs)
      const latest = runs?.workflow_runs?.[0]
      if (latest) setDvcLog(l => [...l, `[${ts()}] Latest run: #${latest.run_number} — ${latest.status}. View: ${latest.html_url}`])
    } catch (err) {
      setDvcLog(l => [...l, `[${ts()}] Error: ${err.message}`])
    } finally {
      setDvcRunning(false)
    }
  }

  const refreshDvcRuns = async () => {
    for (const wf of ['dvc-push.yml', 'dvc-pull.yml']) {
      const r = await getGitHubWorkflowRuns(wf)
      if (r?.workflow_runs?.length) { setDvcRuns(r); break }
    }
  }

  // ── Fetch DVC tracked datasets via GitHub API ──────────────────────────
  const fetchDvcDatasets = async () => {
    setDvcDatasetsLoading(true)
    const { ghToken, ghOwner, ghRepo, ghBranch } = getGitHubConfig()
    if (!ghToken || !ghOwner || !ghRepo) { setDvcDatasetsLoading(false); return }
    try {
      const res = await fetch(
        `https://api.github.com/repos/${ghOwner}/${ghRepo}/contents?ref=${ghBranch}`,
        { headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json' } }
      )
      if (!res.ok) throw new Error(`GitHub API ${res.status}`)
      const files = await res.json()
      const dvcFiles = files.filter(f => f.name.endsWith('.dvc') && f.name.startsWith('data_'))
      const datasets = []
      for (const df of dvcFiles) {
        const contentRes = await fetch(df.download_url)
        const content = await contentRes.text()
        const leafType = df.name.replace('data_', '').replace('.dvc', '')
        const sizeMatch = content.match(/size:\s*(\d+)/)
        const nfilesMatch = content.match(/nfiles:\s*(\d+)/)
        const md5Match = content.match(/md5:\s*(\S+)/)
        datasets.push({
          name: leafType,
          file: df.name,
          size: sizeMatch ? parseInt(sizeMatch[1]) : null,
          nfiles: nfilesMatch ? parseInt(nfilesMatch[1]) : null,
          md5: md5Match ? md5Match[1] : null,
        })
      }
      setDvcDatasets(datasets)
    } catch (err) {
      console.warn('Failed to fetch DVC datasets:', err.message)
    }
    setDvcDatasetsLoading(false)
  }

  // ── Preview predictions for dataset export ──────────────────────────────
  const previewPredictions = async () => {
    if (!dsLeafType) return
    const { data, error } = await supabase
      .from('predictions')
      .select('predicted_class_name, confidence')
      .eq('leaf_type', dsLeafType)
      .gte('confidence', dsConfThreshold)
    if (error || !data) { setDsPredPreview(null); return }
    const classMap = {}
    data.forEach(r => { classMap[r.predicted_class_name] = (classMap[r.predicted_class_name] || 0) + 1 })
    setDsPredPreview({ total: data.length, classes: classMap })
  }

  // ── Trigger dataset upload workflow ──────────────────────────────────────
  const triggerDatasetUpload = async (source, inputs) => {
    setDsUploading(true); setDsMsg(null)
    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations.')
      await triggerGitHubWorkflow('dataset-upload.yml', { source, ...inputs })
      setDsMsg({ type: 'success', text: `Dataset upload workflow dispatched (source: ${source}). Check GitHub Actions for progress.` })
    } catch (err) {
      setDsMsg({ type: 'error', text: err.message })
    } finally {
      setDsUploading(false)
    }
  }

  // ── CSV Import into predictions table ─────────────────────────────────────
  const parseCSV = async (file) => {
    const text = await file.text()
    const lines = text.split('\n').filter(l => l.trim())
    if (lines.length < 2) { setCsvMsg({ type: 'error', text: 'CSV has no data rows.' }); return }
    const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''))
    const rows = lines.slice(1).map(line => {
      const values = line.match(/(".*?"|[^,]+|(?<=,)(?=,)|^(?=,)|(?<=,)$)/g) || line.split(',')
      const row = {}
      headers.forEach((h, i) => { row[h] = (values[i] || '').trim().replace(/^"|"$/g, '') || null })
      return row
    }).filter(r => Object.values(r).some(v => v))
    setCsvParsed({ headers, rows: rows.slice(0, 10), total: rows.length, all: rows })
    setCsvMsg(null)
  }

  const importCSV = async () => {
    if (!csvParsed) return
    setCsvImporting(true); setCsvProgress(0); setCsvMsg(null)
    const BATCH = 100
    const { all } = csvParsed
    let imported = 0
    try {
      for (let i = 0; i < all.length; i += BATCH) {
        const batch = all.slice(i, i + BATCH)
        const { error } = await supabase.from('predictions').insert(batch)
        if (error) throw new Error(`Batch ${Math.floor(i / BATCH) + 1} failed: ${error.message}`)
        imported += batch.length
        setCsvProgress(Math.round(imported / all.length * 100))
      }
      setCsvMsg({ type: 'success', text: `✓ Imported ${imported.toLocaleString()} records successfully.` })
      setCsvParsed(null); setCsvFile(null); if (csvRef.current) csvRef.current.value = ''
      loadData()
    } catch (err) {
      setCsvMsg({ type: 'error', text: err.message })
    } finally {
      setCsvImporting(false)
    }
  }

  // ── Export ──────────────────────────────────────────────────────────────
  const exportAll = async (fmt) => {
    const { data } = await supabase.from('predictions').select('*').order('created_at', { ascending: false }).limit(50000)
    if (!data?.length) return
    const name = `agrikd-data-${new Date().toISOString().slice(0, 10)}`
    if (fmt === 'csv') {
      const h = Object.keys(data[0])
      downloadFile([h.join(','), ...data.map(r => h.map(k => JSON.stringify(r[k] ?? '')).join(','))].join('\n'), `${name}.csv`, 'text/csv')
    } else {
      downloadFile(JSON.stringify(data, null, 2), `${name}.json`, 'application/json')
    }
  }

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Loading data…</span></div>

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Data & DVC</h1>
        <p className="page-subtitle">Dataset management, quality metrics, cloud sync (DVC), and import/export</p>
      </div>

      {/* Tab nav */}
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {DTABS.map(t => (
          <button key={t} onClick={() => setDtab(t)} style={{ padding: '10px 16px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: dtab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${dtab === t ? '#16a34a' : 'transparent'}`, fontFamily: 'inherit' }}>
            {t}
          </button>
        ))}
      </div>

      {/* ── Overview Tab ── */}
      {dtab === 'Overview' && (
        <>
          <div className="stats-grid" style={{ marginBottom: 16 }}>
            {[
              { label: 'Total Records', value: stats.total.toLocaleString(), accent: '#16a34a' },
            ].map(s => (
              <div key={s.label} className="stat-card" style={{ padding: '14px 16px' }}>
                <div className="stat-card-accent" style={{ background: s.accent }} />
                <div className="stat-label">{s.label}</div>
                <div className="stat-value" style={{ fontSize: 22 }}>{s.value}</div>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-header"><div><div className="card-label">Quality Metrics</div><div className="card-title">Data Quality by Leaf Type</div></div></div>
            <table>
              <thead><tr><th>Leaf Type</th><th>Total Records</th><th>High Confidence (%)</th></tr></thead>
              <tbody>
                {quality.map(q => (
                  <tr key={q.name}>
                    <td><strong style={{ color: '#121c28' }}>{q.name}</strong></td>
                    <td>{q.total.toLocaleString()}</td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div className="progress-track" style={{ flex: 1 }}><div className="progress-fill" style={{ width: `${q.highConf}%` }} /></div>
                        <span style={{ fontSize: 12, color: '#64748b', minWidth: 30 }}>{q.highConf}%</span>
                      </div>
                    </td>
                  </tr>
                ))}
                {quality.length === 0 && <tr><td colSpan={3} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No data yet</td></tr>}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ── Upload Dataset Tab ── */}
      {dtab === 'Upload Dataset' && (
        <div style={{ display: 'flex', gap: 20, flexWrap: 'wrap' }}>
          {/* Method A: From Predictions */}
          <div className="card" style={{ flex: 1, minWidth: 340 }}>
            <div className="card-header"><div><div className="card-label">Method A</div><div className="card-title">From User Predictions</div></div></div>
            <div className="alert alert-info" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
              <div>Export high-confidence predictions as a labeled dataset. Images are downloaded and organized into <code>data/{'{leaf_type}'}/{'{class}'}/</code> structure, then pushed to DVC.</div>
            </div>
            <div className="form-group">
              <label className="form-label">Leaf Type *</label>
              <select className="form-input" value={dsLeafType} onChange={e => { setDsLeafType(e.target.value); setDsPredPreview(null) }}>
                <option value="">Select leaf type…</option>
                {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">Min. Confidence Threshold</label>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <input type="range" min="0.5" max="1" step="0.05" value={dsConfThreshold} onChange={e => setDsConfThreshold(parseFloat(e.target.value))} style={{ flex: 1 }} />
                <span style={{ fontSize: 13, fontWeight: 600, minWidth: 40 }}>{(dsConfThreshold * 100).toFixed(0)}%</span>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
              <button className="btn btn-sm" onClick={previewPredictions} disabled={!dsLeafType}>Preview Count</button>
            </div>
            {dsPredPreview && (
              <div style={{ marginBottom: 14, padding: '10px 14px', background: '#f8fafc', borderRadius: 8, fontSize: 13 }}>
                <div style={{ fontWeight: 600, marginBottom: 6 }}>Found {dsPredPreview.total} images:</div>
                {Object.entries(dsPredPreview.classes).map(([cls, n]) => (
                  <div key={cls} style={{ display: 'flex', justifyContent: 'space-between', padding: '2px 0' }}>
                    <span>{cls}</span><span style={{ color: '#64748b' }}>{n}</span>
                  </div>
                ))}
              </div>
            )}
            <button className="btn btn-primary" disabled={dsUploading || !dsLeafType || !dsPredPreview?.total}
              onClick={() => triggerDatasetUpload('predictions', { leaf_type: dsLeafType, confidence_threshold: String(dsConfThreshold) })}>
              {dsUploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Triggering…</> : 'Export as Dataset'}
            </button>
          </div>

          {/* Method B: Google Drive ZIP */}
          <div className="card" style={{ flex: 1, minWidth: 340 }}>
            <div className="card-header"><div><div className="card-label">Method B</div><div className="card-title">Upload ZIP via Google Drive</div></div></div>
            <div className="alert alert-info" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
              <div>Upload a ZIP file to Google Drive, paste the share link below. The pipeline will download, extract, validate structure, generate config, and push to DVC.<br/><br/>
              <strong>ZIP structure:</strong> <code>dataset_name/class_name/images.*</code></div>
            </div>
            <div className="form-group">
              <label className="form-label">Google Drive Share URL *</label>
              <input className="form-input" placeholder="https://drive.google.com/file/d/..." value={dsGdriveUrl} onChange={e => setDsGdriveUrl(e.target.value)} />
            </div>
            <div className="form-group">
              <label className="form-label">Leaf Type ID *</label>
              <input className="form-input" placeholder="e.g. mango, cassava_leaf" value={dsGdriveLeaf} onChange={e => setDsGdriveLeaf(e.target.value)} />
              <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 4 }}>Lowercase, underscores. Used for config and DVC tracking.</div>
            </div>
            <div className="form-group">
              <label className="form-label">Display Name</label>
              <input className="form-input" placeholder="e.g. Mango Leaf Disease" value={dsGdriveName} onChange={e => setDsGdriveName(e.target.value)} />
            </div>
            <button className="btn btn-primary" disabled={dsUploading || !dsGdriveUrl || !dsGdriveLeaf}
              onClick={() => triggerDatasetUpload('gdrive', { leaf_type: dsGdriveLeaf, gdrive_url: dsGdriveUrl, display_name: dsGdriveName || dsGdriveLeaf })}>
              {dsUploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Triggering…</> : 'Start Upload Pipeline'}
            </button>
          </div>

          {/* Shared status message */}
          {dsMsg && (
            <div style={{ width: '100%' }}>
              <div className={`alert ${dsMsg.type === 'error' ? 'alert-error' : 'alert-success'}`}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div>{dsMsg.text}</div>
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── Import CSV Tab ── */}
      {dtab === 'Import CSV' && (
        <div style={{ maxWidth: 700 }}>
          <div className="card">
            <div className="card-header"><div><div className="card-label">Database</div><div className="card-title">Import Predictions from CSV</div></div></div>
            <div className="alert alert-warn" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
              <div>CSV must have headers matching <code>predictions</code> table columns. Required: <code>leaf_type</code>, <code>predicted_class_name</code>, <code>confidence</code>. Optional: <code>user_id, notes, model_version, created_at</code>.</div>
            </div>
            <div className="form-group">
              <label className="form-label">CSV File</label>
              <input ref={csvRef} type="file" accept=".csv,text/csv" className="form-input" style={{ padding: '7px 10px' }} onChange={e => { setCsvFile(e.target.files[0]); setCsvParsed(null); setCsvMsg(null); if (e.target.files[0]) parseCSV(e.target.files[0]) }} />
            </div>

            {csvParsed && (
              <div style={{ marginBottom: 16 }}>
                <div className="alert alert-success" style={{ marginBottom: 10 }}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                  <div>Parsed <strong>{csvParsed.total.toLocaleString()}</strong> rows. Columns: {csvParsed.headers.join(', ')}</div>
                </div>
                <div style={{ overflowX: 'auto', border: '1px solid rgba(0,0,0,0.08)', borderRadius: 8 }}>
                  <table>
                    <thead><tr>{csvParsed.headers.map(h => <th key={h}>{h}</th>)}</tr></thead>
                    <tbody>
                      {csvParsed.rows.map((r, i) => <tr key={i}>{csvParsed.headers.map(h => <td key={h} style={{ maxWidth: 120, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 12 }}>{r[h] ?? ''}</td>)}</tr>)}
                    </tbody>
                  </table>
                  {csvParsed.total > 10 && <div style={{ padding: '6px 12px', fontSize: 12, color: '#94a3b8', borderTop: '1px solid rgba(0,0,0,0.06)' }}>Showing first 10 of {csvParsed.total.toLocaleString()} rows</div>}
                </div>
              </div>
            )}

            {csvImporting && (
              <div style={{ marginBottom: 12 }}>
                <div className="progress-track"><div className="progress-fill" style={{ width: `${csvProgress}%` }} /></div>
                <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>Importing… {csvProgress}%</div>
              </div>
            )}
            {csvMsg && (
              <div className={`alert ${csvMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                {csvMsg.text}
              </div>
            )}
            {csvParsed && !csvImporting && (
              <button className="btn btn-primary" onClick={importCSV}>
                Import {csvParsed.total.toLocaleString()} Records into Database
              </button>
            )}
          </div>
        </div>
      )}

      {/* ── DVC Sync Tab ── */}
      {dtab === 'DVC Sync' && (
        <div>
          <div className="dvc-panel">
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14 }}>
              <h3>DVC — Data Version Control via GitHub Actions</h3>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <button className="btn btn-sm btn-primary" onClick={() => runDvc('push')} disabled={dvcRunning}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/></svg>
                  Push All
                </button>
                <select
                  value={dvcPullLeaf}
                  onChange={e => setDvcPullLeaf(e.target.value)}
                  style={{ padding: '5px 8px', borderRadius: 6, border: '1px solid rgba(255,255,255,0.2)', background: 'rgba(255,255,255,0.08)', color: '#fff', fontSize: 12 }}
                >
                  <option value="">All datasets</option>
                  {leafOptions.map(lt => <option key={lt} value={lt}>{lt}</option>)}
                </select>
                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.8)', borderColor: 'rgba(255,255,255,0.15)' }} onClick={() => runDvc('pull', dvcPullLeaf)} disabled={dvcRunning}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>
                  Pull
                </button>
                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.8)', borderColor: 'rgba(255,255,255,0.15)' }} onClick={refreshDvcRuns}>
                  Refresh
                </button>
              </div>
            </div>
            {!getGitHubConfig().ghToken && (
              <div style={{ background: 'rgba(202,138,4,0.15)', border: '1px solid rgba(202,138,4,0.3)', borderRadius: 8, padding: '10px 14px', fontSize: 12, color: '#fde68a', marginBottom: 10 }}>
                GitHub not configured. Go to <strong>Settings - Integrations</strong> to add your token.
              </div>
            )}
            {dvcLog.length > 0 && (
              <div className="dvc-log">
                {dvcLog.map((line, i) => <div key={i}>{line}</div>)}
              </div>
            )}
          </div>

          {/* DVC Tracked Datasets */}
          <div className="card">
            <div className="card-header">
              <div><div className="card-label">DVC Remote</div><div className="card-title">Tracked Datasets</div></div>
              <button className="btn btn-sm" onClick={fetchDvcDatasets} disabled={dvcDatasetsLoading}>
                {dvcDatasetsLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading…</> : 'Load from GitHub'}
              </button>
            </div>
            {dvcDatasets.length > 0 ? (
              <table>
                <thead><tr><th>Dataset</th><th>DVC File</th><th>Files</th><th>Size</th><th>MD5</th></tr></thead>
                <tbody>
                  {dvcDatasets.map(ds => (
                    <tr key={ds.name}>
                      <td><strong style={{ color: '#121c28' }}>{ds.name}</strong></td>
                      <td style={{ fontSize: 12 }}><code>{ds.file}</code></td>
                      <td>{ds.nfiles != null ? ds.nfiles.toLocaleString() : '—'}</td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>{ds.size != null ? formatBytes(ds.size) : '—'}</td>
                      <td style={{ fontSize: 11, color: '#94a3b8', fontFamily: 'monospace' }}>{ds.md5 ? ds.md5.slice(0, 12) + '…' : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <div className="empty-state"><p>Click "Load from GitHub" to fetch DVC tracking info from your repo.</p></div>
            )}
          </div>

          {dvcRuns && (
            <div className="card">
              <div className="card-header"><div><div className="card-label">Recent</div><div className="card-title">DVC Workflow Runs</div></div></div>
              {dvcRuns.workflow_runs?.map(run => (
                <div key={run.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                  <div>
                    <span className={`status-dot ${run.conclusion === 'success' ? 'green' : run.status === 'in_progress' ? 'yellow' : 'red'}`} style={{ marginRight: 8 }} />
                    <a href={run.html_url} target="_blank" rel="noopener noreferrer" style={{ color: '#121c28', textDecoration: 'none', fontWeight: 500 }}>Run #{run.run_number} — {run.name}</a>
                  </div>
                  <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                    <span className={`badge ${run.conclusion === 'success' ? 'badge-green' : run.status === 'in_progress' ? 'badge-yellow' : 'badge-red'}`}>{run.status === 'in_progress' ? 'Running' : run.conclusion || run.status}</span>
                    <span style={{ fontSize: 11, color: '#94a3b8' }}>{new Date(run.created_at).toLocaleString()}</span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ── Export Tab ── */}
      {dtab === 'Export' && (
        <div className="card" style={{ maxWidth: 500 }}>
          <div className="card-header"><div><div className="card-label">Export</div><div className="card-title">Download Dataset</div></div></div>
          <p style={{ fontSize: 13, color: '#64748b', marginBottom: 20 }}>Export up to 50,000 most recent prediction records from the database.</p>
          <div style={{ display: 'flex', gap: 12 }}>
            <button className="btn btn-primary" style={{ flex: 1, justifyContent: 'center' }} onClick={() => exportAll('csv')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 10v6m0 0l-3-3m3 3l3-3M3 17V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
              Export CSV
            </button>
            <button className="btn" style={{ flex: 1, justifyContent: 'center' }} onClick={() => exportAll('json')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 10v6m0 0l-3-3m3 3l3-3M3 17V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
              Export JSON
            </button>
          </div>
        </div>
      )}

      {/* ── Storage Files Tab ── */}
      {dtab === 'Storage Files' && (
        <div>
          {/* DVC Tracked Datasets */}
          <div className="card" style={{ marginBottom: 20 }}>
            <div className="card-header">
              <div><div className="card-label">DVC Remote</div><div className="card-title">DVC Tracked Datasets (Google Drive)</div></div>
              <button className="btn btn-sm" onClick={fetchDvcDatasets} disabled={dvcDatasetsLoading}>
                {dvcDatasetsLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading…</> : 'Refresh'}
              </button>
            </div>
            {dvcDatasets.length > 0 ? (
              <table>
                <thead><tr><th>Dataset</th><th>DVC File</th><th>Files</th><th>Total Size</th></tr></thead>
                <tbody>
                  {dvcDatasets.map(ds => (
                    <tr key={ds.name}>
                      <td><span className="badge badge-primary">{ds.name}</span></td>
                      <td style={{ fontSize: 12 }}><code>{ds.file}</code></td>
                      <td>{ds.nfiles != null ? ds.nfiles.toLocaleString() : '—'}</td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>{ds.size != null ? formatBytes(ds.size) : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <div className="empty-state"><p>Click "Refresh" to load DVC tracking info from your GitHub repo.</p></div>
            )}
          </div>

          {/* Supabase Storage Files */}
          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Supabase Storage</div><div className="card-title">Uploaded Files</div></div>
              <button className="btn btn-sm btn-primary" onClick={loadStorageFiles} disabled={storageLoading}>
                {storageLoading ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Loading…</> : 'Refresh'}
              </button>
            </div>
            {storageLoading && storedFiles.length === 0 ? (
              <div className="loading-spinner"><div className="spinner" /></div>
            ) : storedFiles.length > 0 ? (
              <div className="table-wrapper">
                <table>
                  <thead><tr><th>Folder</th><th>Filename</th><th>Size</th><th>Created</th><th>Actions</th></tr></thead>
                  <tbody>
                    {storedFiles.map(f => (
                      <tr key={f.path}>
                        <td><span className="badge badge-primary">{f.folder}</span></td>
                        <td style={{ fontSize: 13, maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis' }}>{f.name}</td>
                        <td style={{ fontSize: 12, color: '#64748b' }}>{formatBytes(f.metadata?.size || 0)}</td>
                        <td style={{ fontSize: 12, color: '#94a3b8' }}>{f.created_at ? new Date(f.created_at).toLocaleDateString() : '—'}</td>
                        <td>
                          <div style={{ display: 'flex', gap: 5 }}>
                            <a href={supabase.storage.from('datasets').getPublicUrl(f.path).data.publicUrl} target="_blank" rel="noopener noreferrer" className="btn btn-sm">Download</a>
                            <button className="btn btn-sm btn-danger" onClick={() => deleteStorageFile(f)}>Delete</button>
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="empty-state"><p>No files in Supabase Storage datasets bucket.</p></div>
            )}
          </div>
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )

  async function loadStorageFiles() {
    setStorageLoading(true)
    try {
      const { data: folders } = await supabase.storage.from('datasets').list('', { limit: 100 })
      const allFiles = []
      for (const folder of (folders || [])) {
        if (folder.id) {
          allFiles.push({ ...folder, folder: '(root)', path: folder.name })
          continue
        }
        const { data: files } = await supabase.storage.from('datasets').list(folder.name, { limit: 100 })
        for (const f of (files || [])) {
          allFiles.push({ ...f, folder: folder.name, path: `${folder.name}/${f.name}` })
        }
      }
      setStoredFiles(allFiles)
    } catch (err) { setError('Failed to list storage: ' + err.message) }
    setStorageLoading(false)
  }

  function deleteStorageFile(f) {
    setConfirmAction({
      title: 'Delete File',
      message: `Permanently delete "${f.name}" from datasets/${f.folder}? This cannot be undone.`,
      danger: true,
      confirmLabel: 'Delete',
      onConfirm: async () => {
        setConfirmAction(null)
        const { error } = await supabase.storage.from('datasets').remove([f.path])
        if (error) alert('Delete failed: ' + error.message)
        else loadStorageFiles()
      }
    })
  }
}
