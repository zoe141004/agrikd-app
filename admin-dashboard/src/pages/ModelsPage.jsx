import { useState, useEffect, Fragment, useRef } from 'react'
import { supabase } from '../lib/supabase'
import { useData } from '../lib/DataContext'
import { formatBytes, uploadToStorage, ensureBucket, triggerGitHubWorkflow, getGitHubWorkflowRuns, getGitHubConfig, logAudit } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'

const TABS = ['Registry', 'Benchmarks', 'Upload Model', 'Validate', 'OTA Deploy']

export default function ModelsPage() {
  const { leafTypeOptions: sharedLeafTypes, dvcDatasets, refreshLeafTypes, triggerRefresh, refreshKey } = useData()
  const [tab, setTab] = useState('Registry')
  const [models, setModels] = useState([])
  const [loading, setLoading] = useState(true)
  const [editModal, setEditModal] = useState(null)
  const [validateResult, setValidateResult] = useState({})
  const [validating, setValidating] = useState({})
  const [form, setForm] = useState({})
  const [saving, setSaving] = useState(false)
  const [expandedId, setExpandedId] = useState(null)

  // Upload state
  const [uploadForm, setUploadForm] = useState({ leaf_type: '', display_name: '', version: '1.0.0', description: '', num_classes: '', class_labels_raw: '', is_new_leaf: false, fold: '' })
  const [uploadFile, setUploadFile] = useState(null)
  const [uploading, setUploading] = useState(false)
  const [uploadProgress, setUploadProgress] = useState(0)
  const [uploadMsg, setUploadMsg] = useState(null)
  const fileInputRef = useRef()

  // Validation (pipeline)
  const [valTarget, setValTarget] = useState('')
  const [valVersion, setValVersion] = useState('')
  const [valRunning, setValRunning] = useState(false)
  const [valMsg, setValMsg] = useState(null)
  const [confirmAction, setConfirmAction] = useState(null)
  const [error, setError] = useState(null)

  // Benchmarks
  const [benchmarks, setBenchmarks] = useState([])
  const [benchLeaf, setBenchLeaf] = useState('')
  const [benchVersion, setBenchVersion] = useState('')

  // Registry / OTA filter
  const [regLeaf, setRegLeaf] = useState('')
  const [regVersion, setRegVersion] = useState('')

  // Version history
  const [versions, setVersions] = useState([])
  // expandedVersions reserved for future version history UI

  // Pipeline tracking (Supabase Realtime + GitHub API polling fallback)
  const [pipelineStatus, setPipelineStatus] = useState(null)
  const [pipelineRuns, setPipelineRuns] = useState([])
  const [pipelineDismissed, setPipelineDismissed] = useState(false)
  const realtimeChannelRef = useRef(null)
  const ghPollRef = useRef(null)

  // Cleanup realtime + polling on unmount
  useEffect(() => () => {
    if (realtimeChannelRef.current) {
      supabase.removeChannel(realtimeChannelRef.current)
      realtimeChannelRef.current = null
    }
    if (ghPollRef.current) {
      clearInterval(ghPollRef.current)
      ghPollRef.current = null
    }
  }, [])

  useEffect(() => { loadModels(); loadPipelineRuns() }, [refreshKey])

  const loadModels = async () => {
    setLoading(true)
    try {
      const [registryRes, benchRes, verRes] = await Promise.allSettled([
        supabase.from('model_registry').select('*').order('leaf_type', { ascending: true }).order('updated_at', { ascending: false }).limit(100),
        supabase.from('model_benchmarks').select('*').order('created_at', { ascending: false }).limit(100),
        supabase.from('model_versions').select('*').order('archived_at', { ascending: false }).limit(100),
      ])
      const data = registryRes.status === 'fulfilled' ? registryRes.value?.data : null
      const benchData = benchRes.status === 'fulfilled' ? benchRes.value?.data : null
      const verData = verRes.status === 'fulfilled' ? verRes.value?.data : null
      if (registryRes.status === 'fulfilled' && registryRes.value?.error) throw new Error(registryRes.value.error.message)
      if (benchRes.status === 'fulfilled' && benchRes.value?.error) console.warn('Benchmarks load error:', benchRes.value.error.message)
      if (verRes.status === 'fulfilled' && verRes.value?.error) console.warn('Version history load error:', verRes.value.error.message)
      setModels(data || [])
      setBenchmarks(benchData || [])
      setVersions(verData || [])
      // Leaf types now come from shared DataContext (includes predictions + registry + dvc_operations)
    } catch (err) { setError(err.message) }
    setLoading(false)
  }

  const loadPipelineRuns = async () => {
    try {
      const { data } = await supabase.from('pipeline_runs').select('*').order('started_at', { ascending: false }).limit(10)
      const runs = data || []

      // Auto-cleanup stale runs: if a non-terminal run is >30 min old, mark it failed
      const STALE_MS = 30 * 60 * 1000
      for (const run of runs) {
        if (['pending', 'converting', 'evaluating', 'uploading'].includes(run.status)) {
          const age = Date.now() - new Date(run.started_at).getTime()
          if (age > STALE_MS) {
            await supabase.from('pipeline_runs').update({
              status: 'failed',
              error_message: 'Stale: no update for >30 minutes',
              completed_at: new Date().toISOString(),
            }).eq('id', run.id)
            run.status = 'failed'
            run.error_message = 'Stale: no update for >30 minutes'
          }
        }
      }

      setPipelineRuns(runs)
      // Derive banner status from latest run
      if (runs.length) {
        const latest = runs[0]
        if (['pending', 'converting', 'evaluating', 'uploading'].includes(latest.status)) {
          setPipelineStatus(latest.status)
          setPipelineDismissed(false)
        } else if (latest.status === 'completed') {
          setPipelineStatus('completed')
        } else if (latest.status === 'failed') {
          setPipelineStatus('failed')
        }
      }
    } catch (err) {
      console.warn('pipeline_runs load failed:', err.message)
    }
  }

  const cancelPipeline = async () => {
    const latestRunning = pipelineRuns.find(r => ['pending', 'converting', 'evaluating', 'uploading'].includes(r.status))
    if (!latestRunning) return
    await supabase.from('pipeline_runs').update({
      status: 'failed',
      error_message: 'Manually cancelled by admin',
      completed_at: new Date().toISOString(),
    }).eq('id', latestRunning.id)
    setPipelineStatus('failed')
    setPipelineRuns(prev => prev.map(r => r.id === latestRunning.id ? { ...r, status: 'failed', error_message: 'Manually cancelled by admin' } : r))
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }
    logAudit(supabase, 'pipeline_cancelled', 'pipeline_run', latestRunning.id, { leaf_type: latestRunning.leaf_type, version: latestRunning.version })
  }

  // GitHub API polling fallback for pipeline tracking
  const startGitHubPolling = () => {
    if (ghPollRef.current) clearInterval(ghPollRef.current)
    ghPollRef.current = setInterval(async () => {
      try {
        const data = await getGitHubWorkflowRuns('model-pipeline.yml')
        if (!data?.workflow_runs?.length) return
        const latest = data.workflow_runs[0]
        // Only consider recent runs (within last 30 minutes)
        const runAge = Date.now() - new Date(latest.created_at).getTime()
        if (runAge > 30 * 60 * 1000) return

        let mappedStatus = null
        if (latest.status === 'queued') mappedStatus = 'pending'
        else if (latest.status === 'in_progress') mappedStatus = 'converting'
        else if (latest.status === 'completed' && latest.conclusion === 'success') mappedStatus = 'completed'
        else if (latest.status === 'completed' && latest.conclusion === 'failure') mappedStatus = 'failed'

        if (mappedStatus) {
          setPipelineStatus(mappedStatus)
          setPipelineDismissed(false)
          // Update pipeline runs list with GitHub data
          setPipelineRuns(prev => {
            const existsWithUrl = prev.some(r => r.github_run_url === latest.html_url)
            if (!existsWithUrl && prev.length > 0) {
              return prev.map((r, i) => i === 0 ? { ...r, github_run_url: latest.html_url, github_run_id: latest.id } : r)
            }
            return prev
          })
          if (['completed', 'failed'].includes(mappedStatus)) {
            clearInterval(ghPollRef.current)
            ghPollRef.current = null
            loadModels()
          }
        }
      } catch { /* GitHub API may not be configured */ }
    }, 15000)
  }

  const subscribeToPipelineRun = (runId) => {
    if (realtimeChannelRef.current) {
      supabase.removeChannel(realtimeChannelRef.current)
    }
    // Start GitHub API polling as fallback (in case Realtime is not enabled)
    startGitHubPolling()
    const channel = supabase
      .channel(`pipeline-${runId}`)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'pipeline_runs',
        filter: `id=eq.${runId}`
      }, (payload) => {
        const newStatus = payload.new.status
        setPipelineStatus(newStatus)
        setPipelineDismissed(false)
        // Update the run in our local list
        setPipelineRuns(prev => prev.map(r => r.id === runId ? { ...r, ...payload.new } : r))
        if (['completed', 'failed'].includes(newStatus)) {
          supabase.removeChannel(channel)
          realtimeChannelRef.current = null
          // Stop GitHub polling since Realtime is working
          if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
          loadModels()
        }
      })
      .subscribe((status) => {
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          console.warn('Realtime subscription failed — relying on GitHub API polling fallback')
        }
      })
    realtimeChannelRef.current = channel
  }

  // ── Registry Tab ──────────────────────────────────────────────────────────
  const openEdit = (m) => {
    setForm({ display_name: m.display_name, version: m.version, model_url: m.model_url || '', description: m.description || '', status: m.status || 'staging', accuracy_top1: m.accuracy_top1 || '', sha256_checksum: m.sha256_checksum || '' })
    setEditModal(m)
  }

  const saveModel = async () => {
    setSaving(true)
    try {
      const trimmedVersion = form.version?.trim()
      if (!trimmedVersion) throw new Error('Version is required.')
      if (!/^\d+\.\d+\.\d+$/.test(trimmedVersion)) throw new Error('Version must be in semver format (e.g. 1.0.0).')
      if (form.accuracy_top1 !== '' && form.accuracy_top1 != null) {
        const acc = Number(form.accuracy_top1)
        if (isNaN(acc) || acc < 0 || acc > 100) throw new Error('Accuracy must be between 0 and 100.')
      }
      // If version changed, cascade rename to benchmarks & version archives
      const versionChanged = trimmedVersion !== editModal.version
      // Block status change to 'active' via edit — must use Activate button
      if (form.status === 'active' && editModal.status !== 'active') {
        throw new Error('Use the "Activate" button to set a model to active status.')
      }
      if (versionChanged) {
        const duplicate = models.find(m => m.leaf_type === editModal.leaf_type && m.version === trimmedVersion && m.id !== editModal.id)
        if (duplicate) throw new Error(`Version v${trimmedVersion} already exists for ${editModal.leaf_type}`)
        const { error: benchErr } = await supabase.from('model_benchmarks').update({ version: trimmedVersion })
          .eq('leaf_type', editModal.leaf_type).eq('version', editModal.version)
        if (benchErr) throw new Error('Benchmark cascade failed: ' + benchErr.message)
        const { error: verErr } = await supabase.from('model_versions').update({ version: trimmedVersion })
          .eq('leaf_type', editModal.leaf_type).eq('version', editModal.version)
        if (verErr) throw new Error('Version archive cascade failed: ' + verErr.message)
      }
      const { error } = await supabase.from('model_registry').update({
        display_name: form.display_name,
        version: trimmedVersion,
        model_url: form.model_url,
        description: form.description,
        status: form.status,
        accuracy_top1: form.accuracy_top1 || null,
        sha256_checksum: form.sha256_checksum || 'pending',
        updated_at: new Date().toISOString(),
      }).eq('id', editModal.id)
      if (error) throw new Error(error.message)
      setEditModal(null); loadModels(); refreshLeafTypes(); triggerRefresh(); logAudit(supabase, 'model_updated', 'model', editModal.id, { leaf_type: editModal.leaf_type, version: trimmedVersion })
    } catch (err) {
      setError('Save failed: ' + err.message)
    }
    setSaving(false)
  }

  const quickValidate = async (m) => {
    setValidating(v => ({ ...v, [m.id]: true }))
    setValidateResult(r => ({ ...r, [m.id]: null }))
    try {
      const errors = []
      const warnings = []
      if (!m.class_labels?.length) errors.push('No class labels configured')
      if (!m.num_classes) errors.push('Number of classes not set')
      if (!m.model_url) {
        warnings.push('No model URL configured (bundled models don\'t need one)')
      } else {
        try {
          // Validate URL scheme before fetching (SSRF prevention)
          const parsedUrl = new URL(m.model_url)
          if (parsedUrl.protocol !== 'https:') throw new Error('Only HTTPS model URLs are allowed')
          const res = await fetch(m.model_url, { method: 'HEAD', signal: AbortSignal.timeout(6000) })
          if (!res.ok) errors.push(`Model URL returned HTTP ${res.status}`)
          else {
            const size = res.headers.get('content-length')
            if (size && parseInt(size) < 1024) errors.push('Model file seems too small (< 1 KB)')
          }
        } catch { warnings.push('Model URL unreachable or CORS blocked') }
      }
      if (!m.sha256_checksum || m.sha256_checksum === 'pending') {
        warnings.push('No SHA-256 checksum recorded (pipeline will compute after conversion)')
      }
      if (!m.accuracy_top1) warnings.push('No accuracy metric recorded')
      const hasBench = benchmarks.some(b => b.leaf_type === m.leaf_type && b.version === m.version)
      if (!hasBench) warnings.push('No benchmark evaluation results')
      const issues = [...errors, ...warnings]
      setValidateResult(r => ({ ...r, [m.id]: { ok: errors.length === 0, issues, errors, warnings } }))
    } finally {
      setValidating(v => ({ ...v, [m.id]: false }))
    }
  }

  const activateModel = async (m) => {
    const hasBench = benchmarks.some(b => b.leaf_type === m.leaf_type && b.version === m.version)
    if (!hasBench || !m.model_url || !m.sha256_checksum || m.sha256_checksum === 'pending') {
      setError('Cannot activate: model must have benchmarks, a valid URL, and SHA-256 checksum.')
      return
    }
    setConfirmAction({
      title: 'Activate Model',
      message: `Activate "${m.display_name || m.leaf_type}" v${m.version}? If there are already 2 active versions for this dataset, the lowest version will be demoted to backup.`,
      danger: false,
      confirmLabel: 'Activate',
      onConfirm: async () => {
        setConfirmAction(null)
        // Archive current active models for this leaf_type before activation
        const activeModels = models.filter(am => am.leaf_type === m.leaf_type && am.status === 'active' && am.id !== m.id)
        for (const am of activeModels) {
          await supabase.from('model_versions').upsert({
            leaf_type: am.leaf_type, version: am.version, display_name: am.display_name,
            model_url: am.model_url, sha256_checksum: am.sha256_checksum,
            accuracy: am.accuracy_top1, size_mb: null,
          }, { onConflict: 'leaf_type,version' })
        }
        // Demotion is handled by the enforce_version_lifecycle DB trigger
        const { error } = await supabase.from('model_registry').update({ status: 'active', updated_at: new Date().toISOString() }).eq('id', m.id)
        if (!error) { loadModels(); refreshLeafTypes(); triggerRefresh(); logAudit(supabase, 'model_activated', 'model', m.id, { leaf_type: m.leaf_type, version: m.version }) }
        else setError(error.message)
      }
    })
  }

  const deactivateModel = async (m) => {
    setConfirmAction({
      title: 'Deactivate Model',
      message: `Deactivate "${m.display_name || m.leaf_type}" v${m.version}? This will stop serving this model to mobile users via OTA. Status will change to backup.`,
      danger: true,
      confirmLabel: 'Deactivate',
      onConfirm: async () => {
        setConfirmAction(null)
        // Archive the model being deactivated into model_versions
        await supabase.from('model_versions').upsert({
          leaf_type: m.leaf_type, version: m.version, display_name: m.display_name,
          model_url: m.model_url, sha256_checksum: m.sha256_checksum,
          accuracy: m.accuracy_top1, size_mb: null,
        }, { onConflict: 'leaf_type,version' })
        const { error } = await supabase.from('model_registry').update({ status: 'backup', updated_at: new Date().toISOString() }).eq('id', m.id)
        if (!error) { loadModels(); refreshLeafTypes(); triggerRefresh(); logAudit(supabase, 'model_deactivated', 'model', m.id, { leaf_type: m.leaf_type, version: m.version }) }
        else setError(error.message)
      }
    })
  }

  const deleteModel = async (m) => {
    const sameLeafModels = models.filter(m2 => m2.leaf_type === m.leaf_type)
    const activeCount = sameLeafModels.filter(m2 => (m2.status || 'staging') === 'active').length
    const isActive = (m.status || 'staging') === 'active'

    // Guard: prevent deleting the last active model
    if (isActive && activeCount <= 1) {
      setError(`Cannot delete the last active model for "${m.leaf_type}". Deactivate first or activate another version.`)
      return
    }

    const isLastModel = sameLeafModels.length <= 1
    const message = isLastModel
      ? `This is the LAST model for "${m.leaf_type}". Deleting it means no models will be available for OTA. The leaf type will still be available for new uploads.\n\nPermanently delete "${m.display_name || m.leaf_type}" v${m.version}?`
      : `Permanently delete "${m.display_name || m.leaf_type}" v${m.version}? This will remove the model file from storage, benchmarks, and the registry entry. This cannot be undone.`

    setConfirmAction({
      title: 'Delete Model Version',
      message,
      danger: true,
      confirmLabel: isLastModel ? 'Delete Last Model' : 'Delete Permanently',
      onConfirm: async () => {
        setConfirmAction(null)
        try {
          // 1. Delete storage file
          if (m.model_url?.includes('supabase.co/storage')) {
            try {
              const match = m.model_url.match(/\/storage\/v1\/object\/public\/models\/(.+)/)
              if (match) await supabase.storage.from('models').remove([decodeURIComponent(match[1])])
            } catch (storageErr) {
              console.warn('Storage file deletion failed (may already be removed):', storageErr.message)
            }
          }
          // 2. Cascade delete benchmarks and version archive
          await supabase.from('model_benchmarks').delete().eq('leaf_type', m.leaf_type).eq('version', m.version)
          await supabase.from('model_versions').delete().eq('leaf_type', m.leaf_type).eq('version', m.version)
          // 3. Delete registry entry
          const { error } = await supabase.from('model_registry').delete().eq('id', m.id)
          if (error) throw new Error(error.message)
          loadModels()
          refreshLeafTypes(); triggerRefresh()
          logAudit(supabase, 'model_deleted', 'model', m.id, { leaf_type: m.leaf_type, version: m.version })
        } catch (err) { setError('Delete failed: ' + err.message) }
      }
    })
  }

  // ── Upload Tab ─────────────────────────────────────────────────────────────
  const handleUpload = async (e) => {
    e.preventDefault()
    if (!uploadFile) { setUploadMsg({ type: 'error', text: 'Please select a model file.' }); return }
    const { leaf_type, display_name, description, num_classes, class_labels_raw, fold } = uploadForm
    const version = uploadForm.version?.trim()
    if (!leaf_type || !version) { setUploadMsg({ type: 'error', text: 'Leaf type and version are required.' }); return }
    if (!/^\d+\.\d+\.\d+$/.test(version)) { setUploadMsg({ type: 'error', text: 'Version must be in semver format (e.g. 1.0.0).' }); return }
    // Append fold suffix to version for DB and pipeline (e.g., "1.2.3-fold5")
    const effectiveVersion = fold ? `${version}-fold${fold}` : version

    setUploading(true); setUploadProgress(10); setUploadMsg(null)

    // Clear any active polling/realtime from previous upload to avoid connection conflicts
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }

    try {
      // 1. Archive current model if exists (match exact leaf_type + version being uploaded)
      const existing = models.find(m => m.leaf_type === leaf_type && m.version === effectiveVersion)
      if (existing) {
        await supabase.from('model_versions').upsert({
          leaf_type: existing.leaf_type,
          version: existing.version,
          display_name: existing.display_name,
          model_url: existing.model_url,
          sha256_checksum: existing.sha256_checksum,
          accuracy: existing.accuracy_top1,
          size_mb: null,
        }, { onConflict: 'leaf_type,version' })
      }
      setUploadProgress(12)

      // 1b. Clear stale benchmarks for this leaf_type+version (prevent UNIQUE conflict)
      await supabase.from('model_benchmarks').delete()
        .eq('leaf_type', leaf_type).eq('version', effectiveVersion)
      setUploadProgress(15)

      // 2. Upload .pth checkpoint to Supabase Storage
      await ensureBucket(supabase, 'models')
      setUploadProgress(20)

      const ext = uploadFile.name.split('.').pop()
      // Use base version (without fold suffix) for clean storage paths
      const storagePath = `${leaf_type}/v${version}/${leaf_type}_v${version}_checkpoint.${ext}`
      setUploadProgress(40)

      const publicUrl = await uploadToStorage(supabase, 'models', storagePath, uploadFile)
      setUploadProgress(70)

      // 3. Parse class labels, fallback to existing model data
      const classLabels = class_labels_raw
        ? class_labels_raw.split('\n').map(l => l.trim()).filter(Boolean)
        : (existing?.class_labels || [])
      const finalNumClasses = num_classes ? parseInt(num_classes) : (classLabels.length || existing?.num_classes || null)

      // 4. Register as STAGING candidate (not auto-activated) — REQ-7
      const payload = {
        leaf_type,
        display_name: display_name || existing?.display_name || leaf_type,
        version: effectiveVersion,
        model_url: publicUrl,
        sha256_checksum: 'pending',
        description: description || existing?.description || null,
        accuracy_top1: null,
        num_classes: finalNumClasses,
        class_labels: classLabels.length ? classLabels : (existing?.class_labels || null),
        status: 'staging',
        updated_at: new Date().toISOString(),
      }

      const { error } = await supabase.from('model_registry').upsert(payload, { onConflict: 'leaf_type,version' })
      setUploadProgress(80)
      if (error) throw new Error(error.message)

      logAudit(supabase, 'model_uploaded', 'model', leaf_type, { version: effectiveVersion, display_name: display_name || leaf_type })

      // 5. Auto-trigger full pipeline
      let pipelineMsg = ''
      try {
        const { ghToken } = getGitHubConfig()
        if (ghToken) {
          // Create pipeline_run record
          let runId = null
          try {
            const { data: { user } } = await supabase.auth.getUser()
            const { data: run, error: runErr } = await supabase.from('pipeline_runs').insert({
              leaf_type, version: effectiveVersion, status: 'pending', triggered_by: user?.id
            }).select().single()
            if (runErr) {
              console.warn('pipeline_runs insert failed:', runErr.message)
              pipelineMsg += ' (Pipeline tracking limited — pipeline_runs table may need setup)'
            }
            runId = run?.id
          } catch (prErr) {
            console.warn('pipeline_runs insert error:', prErr.message)
          }

          await triggerGitHubWorkflow('model-pipeline.yml', {
            leaf_type, version: effectiveVersion, model_url: publicUrl,
            ...(fold ? { fold } : {}),
            ...(runId ? { pipeline_run_id: runId } : {})
          })
          pipelineMsg += ' Full pipeline triggered — track progress in the Validate tab.'
          if (runId) subscribeToPipelineRun(runId)
          else startGitHubPolling()
          setPipelineStatus('pending')
          setPipelineDismissed(false)
          logAudit(supabase, 'pipeline_triggered', 'model', leaf_type, { version: effectiveVersion, workflow: 'model-pipeline.yml' })
        } else {
          pipelineMsg = ' Configure GitHub in Settings to auto-trigger the pipeline.'
        }
      } catch (pipeErr) {
        pipelineMsg = ` Pipeline trigger failed: ${pipeErr.message}`
      }

      setUploadProgress(100)
      setUploadMsg({ type: 'success', text: `Checkpoint "${display_name || leaf_type}" v${effectiveVersion} uploaded as staging. Pipeline will convert to ONNX + TFLite, validate, and evaluate.${pipelineMsg}` })
      setUploadFile(null)
      if (fileInputRef.current) fileInputRef.current.value = ''
      loadModels()
      refreshLeafTypes(); triggerRefresh()
    } catch (err) {
      setUploadMsg({ type: 'error', text: err.message })
    } finally {
      setUploading(false)
      setUploadProgress(0)
    }
  }
  const runValidation = async () => {
    if (!valTarget) { setValMsg({ type: 'error', text: 'Select a dataset first.' }); return }
    setValRunning(true); setValMsg(null)

    // Clear any active polling/realtime from previous run
    if (ghPollRef.current) { clearInterval(ghPollRef.current); ghPollRef.current = null }
    if (realtimeChannelRef.current) { supabase.removeChannel(realtimeChannelRef.current); realtimeChannelRef.current = null }

    try {
      const { ghToken } = getGitHubConfig()
      if (!ghToken) throw new Error('GitHub not configured. Go to Settings → Integrations.')

      // Find the specific version to validate
      const targetModels = models.filter(m => m.leaf_type === valTarget)
      const targetModel = valVersion
        ? targetModels.find(m => m.version === valVersion)
        : targetModels[0]
      if (!targetModel) throw new Error('No model found for selected dataset/version.')

      // Create pipeline_run record
      let runId = null
      try {
        const { data: { user } } = await supabase.auth.getUser()
        const { data: run, error: runErr } = await supabase.from('pipeline_runs').insert({
          leaf_type: valTarget, version: targetModel.version, status: 'pending', triggered_by: user?.id
        }).select().single()
        if (runErr) console.warn('pipeline_runs insert failed:', runErr.message)
        runId = run?.id
      } catch (prErr) {
        console.warn('pipeline_runs insert error:', prErr.message)
      }

      // Parse fold from version string if present (e.g., "1.2.3-fold5")
      const foldMatch = targetModel.version?.match(/-fold(\d+)/)
      const foldParam = foldMatch ? foldMatch[1] : ''

      await triggerGitHubWorkflow('model-pipeline.yml', {
        leaf_type: valTarget, version: targetModel.version,
        model_url: targetModel.model_url || '',
        ...(foldParam ? { fold: foldParam } : {}),
        ...(runId ? { pipeline_run_id: runId } : {})
      })
      setValMsg({ type: 'success', text: `Pipeline dispatched for "${valTarget}" v${targetModel.version}. Track progress in the status banner.` })
      if (runId) subscribeToPipelineRun(runId)
      else startGitHubPolling()
      setPipelineStatus('pending')
      setPipelineDismissed(false)
      loadPipelineRuns()
      logAudit(supabase, 'pipeline_triggered', 'model', valTarget, { version: targetModel.version, workflow: 'model-pipeline.yml' })
    } catch (err) {
      setValMsg({ type: 'error', text: err.message })
    } finally {
      setValRunning(false)
    }
  }

  // ── Benchmarks helpers ────────────────────────────────────────────────────
  const getBenchmarksForModel = (leafType, version) =>
    benchmarks.filter(b => b.leaf_type === leafType && b.version === version)

  const getVersionsForLeaf = (leafType) =>
    versions.filter(v => v.leaf_type === leafType).sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))

  // Available leaf types and versions from benchmark data (filtered to registry-matching only)
  const registryKeys = new Set(models.map(m => `${m.leaf_type}|${m.version}`))
  const registryBenchmarks = benchmarks.filter(b => registryKeys.has(`${b.leaf_type}|${b.version}`))
  const orphanedBenchmarkCount = benchmarks.length - registryBenchmarks.length
  const benchLeafTypes = [...new Set(registryBenchmarks.map(b => b.leaf_type))].sort()
  const activeBenchLeaf = benchLeaf || benchLeafTypes[0] || ''
  const activeBenchVersions = activeBenchLeaf
    ? [...new Set(registryBenchmarks.filter(b => b.leaf_type === activeBenchLeaf).map(b => b.version))].sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
    : []
  const resolvedBenchVersion = benchVersion || activeBenchVersions[0] || ''

  // Versions available for validation target
  const valVersionsForLeaf = valTarget
    ? [...new Set(models.filter(m => m.leaf_type === valTarget).map(m => m.version))].sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
    : []

  const purgeOrphanedBenchmarks = async () => {
    const orphaned = benchmarks.filter(b => !registryKeys.has(`${b.leaf_type}|${b.version}`))
    if (!orphaned.length) return
    setConfirmAction({
      title: 'Purge Orphaned Benchmarks',
      message: `Delete ${orphaned.length} benchmark records for model versions that no longer exist in registry? This cannot be undone.`,
      danger: true,
      confirmLabel: `Delete ${orphaned.length} records`,
      onConfirm: async () => {
        setConfirmAction(null)
        for (const b of orphaned) {
          await supabase.from('model_benchmarks').delete().eq('id', b.id)
        }
        loadModels(); triggerRefresh()
      }
    })
  }

  const pipelineRunning = ['pending', 'converting', 'evaluating', 'uploading'].includes(pipelineStatus)

  // Merged leaf type options: shared context + registry-local types
  const registryLeafTypes = [...new Set(models.map(m => m.leaf_type))].filter(Boolean)
  const leafTypeOptions = [...new Set([...sharedLeafTypes, ...registryLeafTypes])].sort()

  // Registry / OTA — derived filter values
  const regLeafTypes = [...new Set(models.map(m => m.leaf_type))].sort()
  const activeRegLeaf = regLeaf || regLeafTypes[0] || ''
  const regVersions = activeRegLeaf
    ? [...new Set(models.filter(m => m.leaf_type === activeRegLeaf).map(m => m.version))].sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
    : []
  const filteredModels = models
    .filter(m => m.leaf_type === activeRegLeaf && (!regVersion || m.version === regVersion))
    .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))

  // Group filtered models by leaf_type for OTA display, sorted by version desc
  const otaModels = models
    .filter(m => m.leaf_type === activeRegLeaf)
    .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))

  if (loading) return <div className="loading-spinner"><div className="spinner" /><span>Loading models…</span></div>

  return (
    <>
      {error && <div className="alert alert-error" style={{ marginBottom: 16 }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><div>{error}</div></div>}
      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <h1 className="page-title">Model Registry</h1>
          <p className="page-subtitle">Manage, upload, and validate leaf disease detection models (OTA)</p>
        </div>
        <button className="btn btn-primary" onClick={() => setTab('Upload Model')}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 4v12m-6-6l6-6 6 6M4 16v2a2 2 0 002 2h12a2 2 0 002-2v-2"/></svg>
          Upload Model
        </button>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {TABS.map(t => (
          <button key={t} onClick={() => setTab(t)} style={{ padding: '10px 18px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: tab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${tab === t ? '#16a34a' : 'transparent'}`, transition: 'all 0.15s', fontFamily: 'inherit' }}>
            {t}
          </button>
        ))}
      </div>

      {/* ── Pipeline Status Banner ── */}
      {pipelineStatus && !pipelineDismissed && (() => {
        const isRunning = ['pending', 'converting', 'evaluating', 'uploading'].includes(pipelineStatus)
        const isSuccess = pipelineStatus === 'completed'
        const isFailed = pipelineStatus === 'failed'
        const bg = isRunning ? '#fef9c3' : isSuccess ? '#dcfce7' : '#fee2e2'
        const border = isRunning ? '#facc15' : isSuccess ? '#22c55e' : '#ef4444'
        const color = isRunning ? '#854d0e' : isSuccess ? '#166534' : '#991b1b'
        const statusLabels = { pending: 'Pipeline pending...', converting: 'Converting formats...', evaluating: 'Running evaluation...', uploading: 'Uploading results...' }
        return (
          <div style={{ padding: '12px 16px', marginBottom: 16, borderRadius: 8, border: `1px solid ${border}`, background: bg, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, fontSize: 13 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, color }}>
              {isRunning && <div className="spinner" style={{ width: 16, height: 16, borderWidth: 2, borderColor: `${border} transparent ${border} transparent` }} />}
              {isSuccess && <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>}
              {isFailed && <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2"><circle cx="12" cy="12" r="10"/><path d="M15 9l-6 6M9 9l6 6"/></svg>}
              <div>
                <strong style={{ fontWeight: 600 }}>
                  {isRunning ? statusLabels[pipelineStatus] || 'Pipeline running...'
                    : isSuccess ? 'Pipeline completed successfully!'
                    : 'Pipeline failed'}
                </strong>
                {isRunning && <div style={{ fontSize: 11, marginTop: 2, opacity: 0.8 }}>Convert PTH → ONNX → TFLite → Validate → Evaluate → Upload results</div>}
                {isSuccess && <div style={{ fontSize: 11, marginTop: 2, opacity: 0.8 }}>Benchmark results are now available in the Benchmarks tab.</div>}
                {isFailed && pipelineRuns[0]?.error_message && <div style={{ fontSize: 11, marginTop: 2, opacity: 0.8 }}>{pipelineRuns[0].error_message}</div>}
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexShrink: 0 }}>
              {pipelineRuns[0]?.github_run_url && (
                <a href={pipelineRuns[0].github_run_url} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ fontSize: 11 }}>View on GitHub</a>
              )}
              {isRunning && <button className="btn btn-sm btn-danger" onClick={cancelPipeline} style={{ fontSize: 11 }}>Cancel Pipeline</button>}
              {!isRunning && <button onClick={() => setPipelineDismissed(true)} style={{ background: 'none', border: 'none', cursor: 'pointer', color, fontSize: 16, padding: '0 4px', lineHeight: 1 }}>&times;</button>}
            </div>
          </div>
        )
      })()}

      {/* ── Registry Tab ── */}
      {tab === 'Registry' && (
        <>
          {/* Filter bar */}
          <div className="card" style={{ marginBottom: 20, padding: '16px 20px' }}>
            <div style={{ display: 'flex', gap: 16, alignItems: 'center', flexWrap: 'wrap' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <label style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', whiteSpace: 'nowrap' }}>Dataset</label>
                <select className="form-input" style={{ width: 200, padding: '6px 10px', fontSize: 13 }} value={activeRegLeaf} onChange={e => { setRegLeaf(e.target.value); setRegVersion('') }}>
                  {regLeafTypes.map(lt => (
                    <option key={lt} value={lt}>{models.find(m => m.leaf_type === lt)?.display_name || lt.replace(/_/g, ' ')}</option>
                  ))}
                </select>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <label style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', whiteSpace: 'nowrap' }}>Version</label>
                <select className="form-input" style={{ width: 140, padding: '6px 10px', fontSize: 13 }} value={regVersion} onChange={e => setRegVersion(e.target.value)}>
                  <option value="">All versions ({regVersions.length})</option>
                  {regVersions.map(v => (
                    <option key={v} value={v}>v{v}</option>
                  ))}
                </select>
              </div>
              <span style={{ fontSize: 11, color: '#94a3b8' }}>{filteredModels.length} model{filteredModels.length !== 1 ? 's' : ''} shown</span>
            </div>
          </div>

          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Registry</div><div className="card-title">{models.find(m => m.leaf_type === activeRegLeaf)?.display_name || activeRegLeaf.replace(/_/g, ' ')} — Models ({filteredModels.length})</div></div>
            </div>
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Leaf Type</th><th>Display Name</th><th>Version</th><th>Classes</th><th>Accuracy</th><th>Status</th><th>Updated</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredModels.map(m => {
                    const status = m.status || 'staging'
                    const statusColor = status === 'active' ? 'badge-green' : status === 'backup' ? 'badge-gray' : 'badge-yellow'
                    const statusDot = status === 'active' ? 'green' : status === 'backup' ? 'gray' : 'yellow'
                    return (
                    <Fragment key={m.id}>
                      <tr>
                        <td><strong style={{ color: '#121c28' }}>{m.leaf_type}</strong></td>
                        <td><div>{m.display_name}</div>{m.description && <div style={{ fontSize: 11, color: '#94a3b8' }}>{m.description}</div>}</td>
                        <td><span className="badge badge-primary">v{m.version}</span></td>
                        <td>{m.num_classes || '—'}</td>
                        <td>
                          {m.accuracy_top1
                            ? <span className={`badge ${parseFloat(m.accuracy_top1) >= 95 ? 'badge-green' : parseFloat(m.accuracy_top1) >= 85 ? 'badge-yellow' : 'badge-red'}`}>{m.accuracy_top1}%</span>
                            : <span style={{ color: '#94a3b8' }}>—</span>}
                        </td>
                        <td>
                          <span className={`badge ${statusColor}`}>
                            <span className={`status-dot ${statusDot}`} />
                            {status.charAt(0).toUpperCase() + status.slice(1)}
                          </span>
                        </td>
                        <td style={{ fontSize: 12, color: '#94a3b8' }}>{new Date(m.updated_at).toLocaleDateString()}</td>
                        <td>
                          <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
                            <button className="btn btn-sm" onClick={() => openEdit(m)}>Edit</button>
                            <button className="btn btn-sm" onClick={() => quickValidate(m)} disabled={validating[m.id]}>
                              {validating[m.id] ? '…' : 'Quick Check'}
                            </button>
                            <button className="btn btn-sm" onClick={() => { setValTarget(m.leaf_type); setValVersion(m.version); setTab('Validate') }}>
                              Deep Validate
                            </button>
                            <button className="btn btn-sm" onClick={() => setExpandedId(expandedId === m.id ? null : m.id)}>
                              {expandedId === m.id ? 'Hide' : 'Labels'}
                            </button>
                            {status === 'active' ? (
                              <button className="btn btn-sm btn-danger" onClick={() => deactivateModel(m)}>Deactivate</button>
                            ) : (
                              <button className="btn btn-sm" onClick={() => activateModel(m)}>Activate</button>
                            )}
                            <button className="btn btn-sm btn-danger" onClick={() => deleteModel(m)}>Delete</button>
                          </div>
                        </td>
                      </tr>
                      {validateResult[m.id] && (
                        <tr key={`vr-${m.id}`}>
                          <td colSpan={8} style={{ padding: '8px 12px 12px' }}>
                            <div className={`alert ${validateResult[m.id].ok ? (validateResult[m.id].warnings?.length ? 'alert-warn' : 'alert-success') : 'alert-warn'}`}>
                              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
                                {validateResult[m.id].ok ? <path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/> : <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>}
                              </svg>
                              <div>
                                {validateResult[m.id].ok && !validateResult[m.id].warnings?.length
                                  ? 'All checks passed — model URL reachable, metadata complete, benchmarks available.'
                                  : <>
                                      {(validateResult[m.id].errors || []).map((e, i) => <div key={`e${i}`} style={{ color: '#dc2626' }}>&#x2716; {e}</div>)}
                                      {(validateResult[m.id].warnings || []).map((w, i) => <div key={`w${i}`} style={{ color: '#d97706' }}>&#x26A0; {w}</div>)}
                                      {validateResult[m.id].ok && <div style={{ marginTop: 4, color: '#16a34a' }}>No critical issues — model is operational.</div>}
                                    </>
                                }
                              </div>
                            </div>
                          </td>
                        </tr>
                      )}
                      {expandedId === m.id && (
                        <tr key={`cl-${m.id}`}>
                          <td colSpan={8} style={{ padding: '4px 12px 14px' }}>
                            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 8 }}>
                              {(Array.isArray(m.class_labels) ? m.class_labels : []).map((label, i) => (
                                <span key={i} className={`chip ${label.toLowerCase().includes('healthy') ? 'chip-green' : ''}`}>
                                  <span style={{ color: '#94a3b8', fontSize: 10 }}>{i}</span> {label.replace(/_/g, ' ')}
                                </span>
                              ))}
                              {!m.class_labels?.length && <span className="text-muted">No class labels configured</span>}
                            </div>
                            {m.model_url && (
                              <div style={{ fontSize: 12, marginBottom: 4 }}>
                                <span style={{ color: '#94a3b8' }}>Model URL: </span>
                                <a href={m.model_url} target="_blank" rel="noopener noreferrer" style={{ color: '#16a34a', wordBreak: 'break-all' }}>{m.model_url}</a>
                              </div>
                            )}
                            {m.sha256_checksum && (
                              <div style={{ fontSize: 12, marginBottom: 8 }}>
                                <span style={{ color: '#94a3b8' }}>SHA-256: </span>
                                <span className="font-mono" style={{ color: '#3d4f62' }}>{m.sha256_checksum}</span>
                              </div>
                            )}
                            {getVersionsForLeaf(m.leaf_type).length > 0 && (
                              <>
                                <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 4, marginTop: 4 }}>Version History</div>
                                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                                  {getVersionsForLeaf(m.leaf_type).map(v => (
                                    <div key={v.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, padding: '4px 8px', background: 'rgba(0,0,0,0.02)', borderRadius: 6 }}>
                                      <span className="badge badge-gray">v{v.version}</span>
                                      <span style={{ color: '#64748b' }}>{v.display_name}</span>
                                      {v.accuracy && <span className="badge badge-yellow">{v.accuracy}%</span>}
                                      <span style={{ color: '#94a3b8', marginLeft: 'auto' }}>Archived {new Date(v.archived_at).toLocaleDateString()}</span>
                                    </div>
                                  ))}
                                </div>
                              </>
                            )}
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  )})}
                  {filteredModels.length === 0 && <tr><td colSpan={8} style={{ textAlign: 'center', color: '#94a3b8', padding: 32 }}>{models.length === 0 ? 'No models registered yet. Upload your first model.' : 'No models match the selected filter.'}</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {/* ── Benchmarks Tab ── */}
      {tab === 'Benchmarks' && (
        <>
          {/* Filters */}
          <div className="card" style={{ marginBottom: 20, padding: '16px 20px' }}>
            <div style={{ display: 'flex', gap: 16, alignItems: 'center', flexWrap: 'wrap' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <label style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', whiteSpace: 'nowrap' }}>Dataset</label>
                <select className="form-input" style={{ width: 200, padding: '6px 10px', fontSize: 13 }} value={activeBenchLeaf} onChange={e => { setBenchLeaf(e.target.value); setBenchVersion('') }}>
                  {benchLeafTypes.map(lt => (
                    <option key={lt} value={lt}>{models.find(m => m.leaf_type === lt)?.display_name || lt.replace(/_/g, ' ')}</option>
                  ))}
                </select>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <label style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', whiteSpace: 'nowrap' }}>Version</label>
                <select className="form-input" style={{ width: 120, padding: '6px 10px', fontSize: 13 }} value={resolvedBenchVersion} onChange={e => setBenchVersion(e.target.value)}>
                  {activeBenchVersions.map(v => (
                    <option key={v} value={v}>v{v}</option>
                  ))}
                </select>
              </div>
              {activeBenchVersions.length > 1 && (
                <span style={{ fontSize: 11, color: '#94a3b8' }}>{activeBenchVersions.length} versions available — compare by switching versions</span>
              )}
              {orphanedBenchmarkCount > 0 && (
                <button className="btn btn-sm btn-danger" style={{ marginLeft: 'auto' }} onClick={purgeOrphanedBenchmarks}>
                  Purge {orphanedBenchmarkCount} orphaned
                </button>
              )}
            </div>
          </div>

          {/* Benchmark results for selected leaf + version */}
          {(() => {
            const modelBench = getBenchmarksForModel(activeBenchLeaf, resolvedBenchVersion)
            const model = models.find(m => m.leaf_type === activeBenchLeaf && m.version === resolvedBenchVersion)
              || models.find(m => m.leaf_type === activeBenchLeaf)

            if (!activeBenchLeaf || !modelBench.length) return (
              <div className="card" style={{ textAlign: 'center', padding: 40, color: '#94a3b8' }}>
                {benchmarks.length === 0
                  ? 'No benchmark data available. Run the pipeline from the Validate tab to generate benchmarks.'
                  : 'No benchmarks for this selection.'}
              </div>
            )

            const tflite16 = modelBench.find(b => b.format === 'tflite_float16')
            const pytorch = modelBench.find(b => b.format === 'pytorch')
            const onnx = modelBench.find(b => b.format === 'onnx')
            const tensorrt = modelBench.find(b => b.format === 'tensorrt_fp16')
            const formats = [pytorch, onnx, tflite16, tensorrt].filter(Boolean)
            const activeTflite = tflite16

            return (
              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-header">
                  <div>
                    <div className="card-label">{model?.display_name || activeBenchLeaf.replace(/_/g, ' ')}</div>
                    <div className="card-title">v{resolvedBenchVersion} — Full Benchmark Results</div>
                  </div>
                  {model && (
                    <span className={`badge ${(model.status || 'staging') === 'active' ? 'badge-green' : (model.status || 'staging') === 'backup' ? 'badge-gray' : 'badge-yellow'}`}>
                      {(model.status || 'staging').charAt(0).toUpperCase() + (model.status || 'staging').slice(1)}
                    </span>
                  )}
                </div>

                {/* Summary metrics cards */}
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
                  {[
                    { label: 'Accuracy', value: activeTflite?.accuracy != null ? `${activeTflite.accuracy.toFixed(4)}%` : '—', color: '#16a34a' },
                    { label: 'F1 Score', value: activeTflite?.f1_macro != null ? activeTflite.f1_macro.toFixed(4) : '—', color: '#0284c7' },
                    { label: 'Latency', value: activeTflite?.latency_mean_ms != null ? `${activeTflite.latency_mean_ms.toFixed(1)} ms` : '—', color: '#7c3aed' },
                    { label: 'Model Size', value: activeTflite?.size_mb != null ? `${activeTflite.size_mb.toFixed(2)} MB` : '—', color: '#ca8a04' },
                  ].map(s => (
                    <div key={s.label} style={{ padding: '10px 14px', borderRadius: 10, border: '1px solid rgba(0,0,0,0.06)', position: 'relative', overflow: 'hidden' }}>
                      <div style={{ position: 'absolute', top: 0, left: 0, width: 3, height: '100%', background: s.color }} />
                      <div style={{ fontSize: 11, color: '#94a3b8', fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.05em' }}>{s.label}</div>
                      <div style={{ fontSize: 18, fontWeight: 700, color: '#121c28', marginTop: 2 }}>{s.value}</div>
                    </div>
                  ))}
                </div>

                {/* Format comparison table */}
                <div style={{ marginBottom: 16 }}>
                  <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 6 }}>Format Comparison</div>
                  <div className="table-wrapper">
                    <table>
                      <thead>
                        <tr>
                          <th>Format</th><th>Accuracy</th><th>Precision</th><th>Recall</th><th>F1</th>
                          <th>Latency</th><th>FPS</th><th>Size</th>
                        </tr>
                      </thead>
                      <tbody>
                        {formats.map(b => (
                          <tr key={b.format}>
                            <td><strong>{b.format === 'tflite_float16' ? 'TFLite (f16)' : b.format === 'tensorrt_fp16' ? 'TensorRT (f16)' : b.format.charAt(0).toUpperCase() + b.format.slice(1)}</strong></td>
                            <td>{b.accuracy != null ? <span className={`badge ${b.accuracy >= 85 ? 'badge-green' : 'badge-yellow'}`}>{b.accuracy.toFixed(4)}%</span> : '—'}</td>
                            <td>{b.precision_macro != null ? b.precision_macro.toFixed(4) : '—'}</td>
                            <td>{b.recall_macro != null ? b.recall_macro.toFixed(4) : '—'}</td>
                            <td>{b.f1_macro != null ? b.f1_macro.toFixed(4) : '—'}</td>
                            <td>{b.latency_mean_ms != null ? `${b.latency_mean_ms.toFixed(1)} ms` : '—'}</td>
                            <td>{b.fps != null ? b.fps.toFixed(0) : '—'}</td>
                            <td>{b.size_mb != null ? `${b.size_mb.toFixed(2)} MB` : '—'}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>

                {/* Per-class metrics */}
                {activeTflite?.per_class_metrics?.length > 0 && (
                  <div>
                    <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 6 }}>Per-Class Metrics ({activeTflite.format === 'tflite_float16' ? 'TFLite float16' : 'TFLite float32'})</div>
                    <div className="table-wrapper">
                      <table>
                        <thead>
                          <tr><th>Class</th><th>Precision</th><th>Recall</th><th>F1-Score</th><th>Support</th></tr>
                        </thead>
                        <tbody>
                          {activeTflite.per_class_metrics.map((c, i) => (
                            <tr key={i}>
                              <td style={{ fontWeight: 500 }}>{c.class?.replace(/_/g, ' ')}</td>
                              <td>{c.precision?.toFixed(4)}</td>
                              <td>{c.recall?.toFixed(4)}</td>
                              <td>
                                <span className={`badge ${c.f1 >= 0.9 ? 'badge-green' : c.f1 >= 0.7 ? 'badge-yellow' : 'badge-red'}`}>
                                  {c.f1?.toFixed(4)}
                                </span>
                              </td>
                              <td style={{ color: '#94a3b8' }}>{c.support}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                )}

                {/* Model complexity info */}
                {pytorch && (pytorch.flops_m != null || pytorch.params_m != null) && (
                  <div style={{ marginTop: 12, fontSize: 12, color: '#64748b', display: 'flex', gap: 16 }}>
                    {pytorch.params_m != null && <span>Parameters: <strong>{pytorch.params_m.toFixed(2)} M</strong></span>}
                    {pytorch.flops_m != null && <span>FLOPs: <strong>{pytorch.flops_m.toFixed(1)} M</strong></span>}
                  </div>
                )}
              </div>
            )
          })()}
        </>
      )}

      {/* ── Upload Model Tab ── */}
      {tab === 'Upload Model' && (
        <div className="card" style={{ maxWidth: 640 }}>
          <div className="card-header">
            <div><div className="card-label">OTA Upload</div><div className="card-title">Register New or Updated Model</div></div>
          </div>
          <div className="alert alert-info" style={{ marginBottom: 16 }}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
            <div>
              Upload a <strong>.pth</strong> PyTorch checkpoint. The pipeline will automatically:
              <br />1. Convert to <strong>ONNX</strong> and <strong>TFLite</strong> formats
              <br />2. Validate cross-format consistency (PyTorch vs ONNX vs TFLite)
              <br />3. Run full evaluation (accuracy, precision, recall, F1, latency, etc.)
              <br />4. Upload the converted <strong>.tflite</strong> to Supabase Storage for OTA
              <br />The model starts as <strong>staging</strong> — review benchmarks before activating.
            </div>
          </div>

          <form onSubmit={handleUpload}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0 16px' }}>
              <div className="form-group">
                <label className="form-label">Leaf Type *</label>
                {uploadForm.is_new_leaf
                  ? <input className="form-input" placeholder="e.g. corn, pepper, mango" value={uploadForm.leaf_type} onChange={e => setUploadForm(f => ({ ...f, leaf_type: e.target.value }))} required />
                  : (
                    <select className="form-input" value={uploadForm.leaf_type} onChange={e => {
                      const lt = e.target.value
                      // Priority 1: existing models in registry
                      const existingModels = models.filter(m => m.leaf_type === lt)
                        .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))
                      const existing = existingModels[0]
                      if (existing) {
                        const labels = Array.isArray(existing.class_labels) ? existing.class_labels.join('\n') : ''
                        const allVersions = existingModels.map(m => m.version).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
                        const curVer = allVersions[0] || '1.0.0'
                        const parts = curVer.split('.')
                        parts[1] = String(parseInt(parts[1] || '0') + 1)
                        if (parts.length > 2) parts[2] = '0'
                        const nextVer = parts.join('.')
                        setUploadForm(f => ({ ...f, leaf_type: lt, display_name: existing.display_name || '', num_classes: String(existing.num_classes || ''), class_labels_raw: labels, version: nextVer }))
                      } else {
                        // Priority 2: DVC dataset metadata from context (auto-filled from upload workflow)
                        const dvcDs = dvcDatasets.find(d => d.name === lt || d.name?.toLowerCase() === lt?.toLowerCase())
                        if (dvcDs?.classes && Object.keys(dvcDs.classes).length > 0) {
                          const classLabels = Object.keys(dvcDs.classes).sort()
                          setUploadForm(f => ({ ...f, leaf_type: lt, display_name: lt.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase()), num_classes: String(classLabels.length), class_labels_raw: classLabels.join('\n'), version: '1.0.0' }))
                        } else {
                          setUploadForm(f => ({ ...f, leaf_type: lt, display_name: lt.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase()), num_classes: dvcDs?.num_classes ? String(dvcDs.num_classes) : '', class_labels_raw: '', version: '1.0.0' }))
                        }
                      }
                    }}>
                      <option value="">Select existing leaf type…</option>
                      {leafTypeOptions.map(lt => {
                        const m = models.find(x => x.leaf_type === lt)
                        return <option key={lt} value={lt}>{m?.display_name || lt.replace(/_/g, ' ')} ({lt})</option>
                      })}
                    </select>
                  )
                }
                <label style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 6, fontSize: 12, color: '#64748b', cursor: 'pointer' }}>
                  <input type="checkbox" checked={uploadForm.is_new_leaf} onChange={e => setUploadForm(f => ({ ...f, is_new_leaf: e.target.checked, leaf_type: '' }))} />
                  Add new leaf type
                </label>
              </div>

              <div className="form-group">
                <label className="form-label">Version *</label>
                <input className="form-input" value={uploadForm.version} onChange={e => setUploadForm(f => ({ ...f, version: e.target.value }))} placeholder="1.0.0" required />
              </div>

              <div className="form-group">
                <label className="form-label">CV Fold (optional)</label>
                <select className="form-input" value={uploadForm.fold} onChange={e => setUploadForm(f => ({ ...f, fold: e.target.value }))}>
                  <option value="">None — standard 70/10/20 split</option>
                  <option value="1">Fold 1</option>
                  <option value="2">Fold 2</option>
                  <option value="3">Fold 3</option>
                  <option value="4">Fold 4</option>
                  <option value="5">Fold 5 (default CV test set)</option>
                </select>
                <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 3 }}>Select a fold to use StratifiedKFold(5) test split for evaluation. Leave empty for standard split.</div>
              </div>

              <div className="form-group">
                <label className="form-label">Display Name</label>
                <input className="form-input" value={uploadForm.display_name} onChange={e => setUploadForm(f => ({ ...f, display_name: e.target.value }))} placeholder="e.g. Tomato Disease Detector" />
              </div>

              <div className="form-group">
                <label className="form-label">Number of Classes</label>
                <input className="form-input" type="number" min="2" value={uploadForm.num_classes} onChange={e => setUploadForm(f => ({ ...f, num_classes: e.target.value }))} placeholder="Auto-detected from labels" />
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">Description</label>
              <input className="form-input" value={uploadForm.description} onChange={e => setUploadForm(f => ({ ...f, description: e.target.value }))} placeholder="Optional notes about this model version" />
            </div>

            <div className="form-group">
              <label className="form-label">Class Labels (one per line)</label>
              <textarea
                className="form-input"
                rows={5}
                value={uploadForm.class_labels_raw}
                onChange={e => setUploadForm(f => ({ ...f, class_labels_raw: e.target.value }))}
                placeholder={"Tomato___Bacterial_spot\nTomato___Early_blight\nTomato___healthy\n..."}
                style={{ resize: 'vertical', fontFamily: 'monospace', fontSize: 12 }}
              />
              <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 3 }}>Format: one label per line, e.g. PlantType___Disease_Name</div>
            </div>

            <div className="form-group">
              <label className="form-label">Model Checkpoint (.pth) *</label>
              <input ref={fileInputRef} type="file" accept=".pth,.pt,.bin" className="form-input" onChange={e => setUploadFile(e.target.files[0])} style={{ padding: '7px 10px' }} />
              {uploadFile && (
                <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>
                  Selected: <strong>{uploadFile.name}</strong> ({formatBytes(uploadFile.size)})
                </div>
              )}
            </div>

            {uploadFile && (
              <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 4, fontStyle: 'italic' }}>
                SHA-256 checksum will be computed automatically for the converted .tflite file by the pipeline.
              </div>
            )}

            <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 8, padding: '10px 14px', marginBottom: 16, fontSize: 12, color: '#166534' }}>
              <strong>Full Pipeline:</strong> .pth → ONNX → TFLite → cross-format validation → full evaluation. The converted <strong>.tflite</strong> and SHA-256 checksum will be set automatically. Model starts as <strong>staging</strong> — review benchmarks before activating.
            </div>

            {uploading && (
              <div style={{ marginBottom: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: '#64748b', marginBottom: 4 }}>
                  <span>Uploading to Supabase Storage…</span><span>{uploadProgress}%</span>
                </div>
                <div className="progress-track"><div className="progress-fill" style={{ width: `${uploadProgress}%` }} /></div>
              </div>
            )}

            {uploadMsg && (
              <div className={`alert ${uploadMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div style={{ wordBreak: 'break-all' }}>{uploadMsg.text}</div>
              </div>
            )}

            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button type="button" className="btn" onClick={() => { setUploadFile(null); setUploadMsg(null); if (fileInputRef.current) fileInputRef.current.value = '' }}>Clear</button>
              <button type="submit" className="btn btn-primary" disabled={uploading || pipelineRunning}>
                {uploading ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Uploading…</> : pipelineRunning ? 'Pipeline Running…' : 'Upload & Register'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* ── Validate Tab ── */}
      {tab === 'Validate' && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Model Pipeline</div><div className="card-title">Validate & Evaluate</div></div>
            </div>
            <p style={{ fontSize: 13, color: '#64748b', marginBottom: 12 }}>
              Triggers the full model pipeline via GitHub Actions:
            </p>
            <div style={{ fontSize: 13, color: '#3d4f62', marginBottom: 16, padding: '10px 14px', background: '#f8fafc', borderRadius: 8, lineHeight: 1.8 }}>
              <strong>1. Format conversion</strong> — Converts .pth checkpoint to ONNX (opset 17) and TFLite (via onnx2tf).<br />
              <strong>2. Cross-format validation</strong> — Checks ONNX and TFLite produce consistent outputs vs PyTorch (tolerance: 1e-4, using 5 random inputs).<br />
              <strong>3. Full evaluation</strong> — Runs all 3 formats on the real test dataset (20% stratified split). Measures accuracy, precision, recall, F1, latency, FPS, model size.<br />
              <strong>4. Upload results</strong> — Uploads converted .tflite to Supabase Storage, writes metrics to database. View in Benchmarks tab.
            </div>

            <div className="form-group">
              <label className="form-label">Dataset</label>
              <select className="form-input" value={valTarget} onChange={e => { setValTarget(e.target.value); setValVersion('') }}>
                <option value="">Select dataset…</option>
                {leafTypeOptions.map(lt => {
                  const m = models.find(x => x.leaf_type === lt)
                  return <option key={lt} value={lt}>{m?.display_name || lt.replace(/_/g, ' ')} ({lt})</option>
                })}
              </select>
            </div>

            {valTarget && valVersionsForLeaf.length > 0 && (
              <div className="form-group">
                <label className="form-label">Version</label>
                <select className="form-input" value={valVersion || valVersionsForLeaf[0]} onChange={e => setValVersion(e.target.value)}>
                  {valVersionsForLeaf.map(v => (
                    <option key={v} value={v}>v{v}</option>
                  ))}
                </select>
              </div>
            )}

            <div className="alert alert-info" style={{ marginBottom: 12 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
              <div>Dispatches <code>model-pipeline.yml</code> workflow. Requires GitHub token in <strong>Settings → Integrations</strong>. Results appear in Benchmarks tab after ~5-10 minutes.</div>
            </div>

            {valMsg && (
              <div className={`alert ${valMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div>{valMsg.text}</div>
              </div>
            )}

            <button className="btn btn-primary" onClick={runValidation} disabled={valRunning || !valTarget || pipelineRunning}>
              {valRunning ? <><div className="spinner" style={{ width: 14, height: 14, borderWidth: 2 }} /> Running…</> : pipelineRunning ? 'Pipeline Running…' : 'Run Pipeline'}
            </button>
          </div>

          <div className="card">
            <div className="card-header">
              <div><div className="card-label">Recent Runs</div><div className="card-title">Pipeline History</div></div>
              <button className="btn btn-sm" onClick={loadPipelineRuns}>Refresh</button>
            </div>
            {pipelineRuns.length === 0 && <p style={{ fontSize: 13, color: '#94a3b8' }}>No pipeline runs yet. Trigger a pipeline to see history here.</p>}
            {pipelineRuns.map(run => {
              const isRunning = ['pending', 'converting', 'evaluating', 'uploading'].includes(run.status)
              const isSuccess = run.status === 'completed'
              return (
                <div key={run.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                  <div>
                    <span className={`status-dot ${isSuccess ? 'green' : isRunning ? 'yellow' : 'red'}`} style={{ marginRight: 8 }} />
                    <strong>{run.leaf_type}</strong> v{run.version}
                    {run.github_run_url && <a href={run.github_run_url} target="_blank" rel="noopener noreferrer" style={{ color: '#16a34a', marginLeft: 8, fontSize: 11 }}>GitHub</a>}
                  </div>
                  <div style={{ textAlign: 'right' }}>
                    <span className={`badge ${isSuccess ? 'badge-green' : isRunning ? 'badge-yellow' : 'badge-red'}`}>{run.status}</span>
                    <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 2 }}>{new Date(run.started_at).toLocaleString()}</div>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* ── OTA Deploy Tab ── */}
      {tab === 'OTA Deploy' && (
        <div className="card">
          <div className="card-header">
            <div><div className="card-label">Over-The-Air</div><div className="card-title">OTA Model Deployment</div></div>
          </div>

          {/* What is OTA explanation */}
          <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 10, padding: '14px 18px', marginBottom: 20 }}>
            <div style={{ fontWeight: 700, fontSize: 14, color: '#166534', marginBottom: 6 }}>What is OTA?</div>
            <p style={{ fontSize: 13, color: '#166534', margin: 0, lineHeight: 1.6 }}>
              OTA (Over-The-Air) allows updating the AI model on users' phones <strong>without</strong> requiring a new app version from the Play Store.
              When you activate a model here, the mobile app automatically detects and downloads it on next launch.
            </p>
          </div>

          {/* OTA flow */}
          <div style={{ background: '#f8fafc', border: '1px solid rgba(0,0,0,0.06)', borderRadius: 10, padding: '14px 18px', marginBottom: 20, fontSize: 12, fontFamily: 'monospace', lineHeight: 2, color: '#3d4f62' }}>
            <div style={{ fontWeight: 700, fontSize: 12, fontFamily: 'inherit', marginBottom: 4, textTransform: 'uppercase', letterSpacing: '0.05em', color: '#94a3b8' }}>Deployment Flow</div>
            Admin uploads model → <strong>Supabase Storage</strong> (status: staging)<br />
            Admin activates model → <code>model_registry.status = 'active'</code> (max 2 active/dataset)<br />
            User opens app → app queries <code>model_registry WHERE status = 'active'</code><br />
            App detects new version → downloads <code>.tflite</code> from <code>model_url</code><br />
            App verifies SHA-256 → loads new model
          </div>

          {/* Filter bar */}
          <div style={{ display: 'flex', gap: 16, alignItems: 'center', flexWrap: 'wrap', marginBottom: 16 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <label style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', whiteSpace: 'nowrap' }}>Dataset</label>
              <select className="form-input" style={{ width: 200, padding: '6px 10px', fontSize: 13 }} value={activeRegLeaf} onChange={e => { setRegLeaf(e.target.value); setRegVersion('') }}>
                {regLeafTypes.map(lt => (
                  <option key={lt} value={lt}>{models.find(m => m.leaf_type === lt)?.display_name || lt.replace(/_/g, ' ')}</option>
                ))}
              </select>
            </div>
            <span style={{ fontSize: 11, color: '#94a3b8' }}>{otaModels.length} version{otaModels.length !== 1 ? 's' : ''}</span>
          </div>

          {/* Deployment status table */}
          <div style={{ fontSize: 12, fontWeight: 600, color: '#3d4f62', marginBottom: 8 }}>Deployment Status — {models.find(m => m.leaf_type === activeRegLeaf)?.display_name || activeRegLeaf.replace(/_/g, ' ')}</div>
          <table>
            <thead>
              <tr><th>Version</th><th>Model URL</th><th>SHA-256</th><th>Benchmarked</th><th>Status</th><th>Actions</th></tr>
            </thead>
            <tbody>
              {otaModels.map(m => {
                const hasBench = benchmarks.some(b => b.leaf_type === m.leaf_type && b.version === m.version)
                const hasUrl = !!m.model_url
                const hasHash = !!m.sha256_checksum && m.sha256_checksum !== 'pending'
                const status = m.status || 'staging'
                const statusColor = status === 'active' ? 'badge-green' : status === 'backup' ? 'badge-gray' : 'badge-yellow'
                return (
                  <tr key={m.id}>
                    <td><span className="badge badge-primary">v{m.version}</span></td>
                    <td>{hasUrl ? <span className="badge badge-green" style={{ fontSize: 10 }}>Uploaded</span> : <span className="badge badge-red" style={{ fontSize: 10 }}>Missing</span>}</td>
                    <td>{hasHash ? <span className="badge badge-green" style={{ fontSize: 10 }}>Recorded</span> : <span className="badge badge-red" style={{ fontSize: 10 }}>Missing</span>}</td>
                    <td>{hasBench ? <span className="badge badge-green" style={{ fontSize: 10 }}>Complete</span> : <span className="badge badge-yellow" style={{ fontSize: 10 }}>Pending</span>}</td>
                      <td><span className={`badge ${statusColor}`}>{status.charAt(0).toUpperCase() + status.slice(1)}</span></td>
                      <td>
                        <div style={{ display: 'flex', gap: 4 }}>
                          {status !== 'active' && (
                            <button className="btn btn-sm" onClick={() => activateModel(m)} disabled={!hasBench || !hasUrl || !hasHash}>Activate</button>
                          )}
                          {status === 'active' && (
                            <button className="btn btn-sm btn-danger" onClick={() => deactivateModel(m)}>Deactivate</button>
                          )}
                          <button className="btn btn-sm btn-danger" onClick={() => deleteModel(m)}>Delete</button>
                        </div>
                      </td>
                    </tr>
                  )
                })}
              {otaModels.length === 0 && <tr><td colSpan={6} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No models for this dataset.</td></tr>}
            </tbody>
          </table>

          {/* Checklist info */}
          <div style={{ marginTop: 16, fontSize: 12, color: '#64748b', lineHeight: 1.8 }}>
            <strong>Deployment checklist:</strong> A model is OTA-ready when all conditions are met:
            <br />1. Model file uploaded to Supabase Storage (model_url set)
            <br />2. SHA-256 checksum recorded (for integrity verification on device)
            <br />3. Benchmark evaluation completed (accuracy verified)
            <br />4. Model set to Active (status = 'active', max 2 per dataset)
          </div>
        </div>
      )}

      {/* Edit Modal */}
      {editModal && (
        <div className="modal-overlay" onClick={() => setEditModal(null)}>
          <div className="modal" style={{ width: 520 }} onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">Edit — {editModal.leaf_type} v{editModal.version}</span>
              <button className="modal-close" onClick={() => setEditModal(null)}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M6 18L18 6M6 6l12 12"/></svg>
              </button>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0 16px' }}>
              <div className="form-group">
                <label className="form-label">Display Name</label>
                <input className="form-input" value={form.display_name} onChange={e => setForm(f => ({ ...f, display_name: e.target.value }))} />
              </div>
              <div className="form-group">
                <label className="form-label">Version</label>
                <input className="form-input" value={form.version} onChange={e => setForm(f => ({ ...f, version: e.target.value }))} />
              </div>
              <div className="form-group" style={{ gridColumn: '1/-1' }}>
                <label className="form-label">Model URL (override)</label>
                <input className="form-input" value={form.model_url} onChange={e => setForm(f => ({ ...f, model_url: e.target.value }))} placeholder="https://…" />
              </div>
              <div className="form-group">
                <label className="form-label">Accuracy (%)</label>
                <input className="form-input" type="number" value={form.accuracy_top1} onChange={e => setForm(f => ({ ...f, accuracy_top1: e.target.value }))} />
              </div>
              <div className="form-group">
                <label className="form-label">SHA-256 Checksum</label>
                <input className="form-input" value={form.sha256_checksum} onChange={e => setForm(f => ({ ...f, sha256_checksum: e.target.value }))} placeholder="hex hash…" style={{ fontFamily: 'monospace', fontSize: 12 }} />
              </div>
              <div className="form-group" style={{ gridColumn: '1/-1' }}>
                <label className="form-label">Description</label>
                <input className="form-input" value={form.description} onChange={e => setForm(f => ({ ...f, description: e.target.value }))} />
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">Status</label>
              <select className="form-input" value={form.status} onChange={e => setForm(f => ({ ...f, status: e.target.value }))}>
                <option value="staging">Staging</option>
                {editModal?.status === 'active' && <option value="active">Active</option>}
                <option value="backup">Backup</option>
              </select>
              {editModal?.status !== 'active' && <p style={{ fontSize: 11, color: '#94a3b8', marginTop: 4 }}>Use the "Activate" button to set a model to active.</p>}
            </div>
            <div className="modal-footer">
              <button className="btn" onClick={() => setEditModal(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={saveModel} disabled={saving}>{saving ? 'Saving…' : 'Save Changes'}</button>
            </div>
          </div>
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )
}
