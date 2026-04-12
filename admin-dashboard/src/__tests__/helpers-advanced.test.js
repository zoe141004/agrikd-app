import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

import {
  getGitHubConfig,
  triggerGitHubWorkflow,
  getGitHubWorkflowRuns,
  computeSHA256,
  logAudit,
  downloadFile,
  uploadToStorage,
  ensureBucket,
} from '../lib/helpers'

// ── getGitHubConfig ─────────────────────────────────────────────────────────

describe('getGitHubConfig', () => {
  beforeEach(() => {
    sessionStorage.clear()
  })

  it('returns empty strings when sessionStorage is empty', () => {
    const cfg = getGitHubConfig()
    expect(cfg.ghToken).toBe('')
    expect(cfg.ghOwner).toBe('')
    expect(cfg.ghRepo).toBe('')
    expect(cfg.ghBranch).toBe('main')
  })

  it('reads values from sessionStorage', () => {
    sessionStorage.setItem('gh_token', 'ghp_test123')
    sessionStorage.setItem('gh_owner', 'my-org')
    sessionStorage.setItem('gh_repo', 'my-repo')
    sessionStorage.setItem('gh_branch', 'develop')

    const cfg = getGitHubConfig()
    expect(cfg.ghToken).toBe('ghp_test123')
    expect(cfg.ghOwner).toBe('my-org')
    expect(cfg.ghRepo).toBe('my-repo')
    expect(cfg.ghBranch).toBe('develop')
  })

  it('defaults branch to main when not set', () => {
    sessionStorage.setItem('gh_token', 'ghp_test')
    sessionStorage.setItem('gh_owner', 'owner')
    sessionStorage.setItem('gh_repo', 'repo')

    const cfg = getGitHubConfig()
    expect(cfg.ghBranch).toBe('main')
  })
})

// ── triggerGitHubWorkflow ───────────────────────────────────────────────────

describe('triggerGitHubWorkflow', () => {
  beforeEach(() => {
    sessionStorage.clear()
    localStorage.clear()
    vi.useFakeTimers()
    globalThis.fetch = vi.fn()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('throws when GitHub is not configured', async () => {
    await expect(triggerGitHubWorkflow('test.yml')).rejects.toThrow(
      'GitHub not configured'
    )
  })

  it('dispatches workflow with correct URL and body', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', 'test-org')
    sessionStorage.setItem('gh_repo', 'test-repo')
    sessionStorage.setItem('gh_branch', 'main')

    globalThis.fetch = vi.fn().mockResolvedValue({ status: 204 })

    const result = await triggerGitHubWorkflow('deploy.yml', { env: 'prod' })
    expect(result).toBe(true)

    expect(fetch).toHaveBeenCalledWith(
      'https://api.github.com/repos/test-org/test-repo/actions/workflows/deploy.yml/dispatches',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ ref: 'main', inputs: { env: 'prod' } }),
      })
    )
  })

  it('throws on non-204 response', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', 'test-org')
    sessionStorage.setItem('gh_repo', 'test-repo')

    globalThis.fetch = vi.fn().mockResolvedValue({
      status: 422,
      json: () => Promise.resolve({ message: 'Validation Failed' }),
    })

    await expect(triggerGitHubWorkflow('bad.yml')).rejects.toThrow(
      'Validation Failed'
    )
  })

  it('sets rate limit after successful dispatch', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', 'test-org')
    sessionStorage.setItem('gh_repo', 'test-repo')

    globalThis.fetch = vi.fn().mockResolvedValue({ status: 204 })

    await triggerGitHubWorkflow('deploy.yml')

    // Second call should be rate-limited
    await expect(triggerGitHubWorkflow('deploy.yml')).rejects.toThrow(
      /Please wait/
    )
  })

  it('rejects SSRF slugs before making API call', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', '../../../etc')
    sessionStorage.setItem('gh_repo', 'repo')

    await expect(triggerGitHubWorkflow('test.yml')).rejects.toThrow(
      'Invalid GitHub owner'
    )
    expect(fetch).not.toHaveBeenCalled()
  })
})

// ── getGitHubWorkflowRuns ───────────────────────────────────────────────────

describe('getGitHubWorkflowRuns', () => {
  beforeEach(() => {
    sessionStorage.clear()
    globalThis.fetch = vi.fn()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('returns null when GitHub is not configured', async () => {
    const result = await getGitHubWorkflowRuns('test.yml')
    expect(result).toBeNull()
  })

  it('returns null on fetch error', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', 'org')
    sessionStorage.setItem('gh_repo', 'repo')

    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 403,
    })

    const result = await getGitHubWorkflowRuns('test.yml')
    expect(result).toBeNull()
  })

  it('returns parsed JSON on success', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', 'org')
    sessionStorage.setItem('gh_repo', 'repo')

    const mockRuns = { total_count: 1, workflow_runs: [{ id: 123 }] }
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(mockRuns),
    })

    const result = await getGitHubWorkflowRuns('ci.yml')
    expect(result).toEqual(mockRuns)
  })

  it('returns null for invalid slugs', async () => {
    sessionStorage.setItem('gh_token', 'ghp_abc')
    sessionStorage.setItem('gh_owner', 'bad slug with spaces')
    sessionStorage.setItem('gh_repo', 'repo')

    const result = await getGitHubWorkflowRuns('test.yml')
    expect(result).toBeNull()
  })
})

// ── computeSHA256 ───────────────────────────────────────────────────────────

// jsdom Blob/File lacks arrayBuffer(), so create a helper that mimics the File API
function createMockFile(content) {
  const encoder = new TextEncoder()
  const buffer = encoder.encode(content)
  return { arrayBuffer: () => Promise.resolve(buffer.buffer) }
}

describe('computeSHA256', () => {
  it('computes correct SHA-256 for known input', async () => {
    const file = createMockFile('Hello')
    const hash = await computeSHA256(file)
    expect(hash).toBe(
      '185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969'
    )
  })

  it('produces different hashes for different content', async () => {
    const file1 = createMockFile('content-a')
    const file2 = createMockFile('content-b')
    const hash1 = await computeSHA256(file1)
    const hash2 = await computeSHA256(file2)
    expect(hash1).not.toBe(hash2)
  })

  it('produces 64-character hex string', async () => {
    const file = createMockFile('test data')
    const hash = await computeSHA256(file)
    expect(hash).toHaveLength(64)
    expect(hash).toMatch(/^[0-9a-f]{64}$/)
  })

  it('handles empty file', async () => {
    const file = createMockFile('')
    const hash = await computeSHA256(file)
    expect(hash).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    )
  })
})

// ── logAudit ────────────────────────────────────────────────────────────────

describe('logAudit', () => {
  it('inserts audit record with user info', async () => {
    const mockInsert = vi.fn().mockResolvedValue({ error: null })
    const mockSupabase = {
      auth: {
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: 'user-123' } },
        }),
      },
      from: vi.fn().mockReturnValue({ insert: mockInsert }),
    }

    await logAudit(mockSupabase, 'delete', 'model', 'model-456', {
      reason: 'cleanup',
    })

    expect(mockSupabase.from).toHaveBeenCalledWith('audit_log')
    expect(mockInsert).toHaveBeenCalledWith({
      user_id: 'user-123',
      action: 'delete',
      entity_type: 'model',
      entity_id: 'model-456',
      details: { reason: 'cleanup' },
    })
  })

  it('handles missing user gracefully', async () => {
    const mockInsert = vi.fn().mockResolvedValue({ error: null })
    const mockSupabase = {
      auth: {
        getUser: vi.fn().mockResolvedValue({
          data: { user: null },
        }),
      },
      from: vi.fn().mockReturnValue({ insert: mockInsert }),
    }

    await logAudit(mockSupabase, 'view', 'dashboard', 'dash-1')

    expect(mockInsert).toHaveBeenCalledWith(
      expect.objectContaining({
        user_id: undefined,
        action: 'view',
      })
    )
  })

  it('does not throw on insert failure', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const mockSupabase = {
      auth: {
        getUser: vi.fn().mockRejectedValue(new Error('auth failed')),
      },
      from: vi.fn(),
    }

    // Should not throw
    await expect(
      logAudit(mockSupabase, 'test', 'entity', 'id')
    ).resolves.toBeUndefined()

    expect(consoleSpy).toHaveBeenCalled()
    consoleSpy.mockRestore()
  })
})

// ── downloadFile ────────────────────────────────────────────────────────────

describe('downloadFile', () => {
  it('creates a download link and triggers click', () => {
    const mockClick = vi.fn()
    const mockCreateElement = vi.spyOn(document, 'createElement')
    const revokeUrl = vi.fn()

    // Mock URL.createObjectURL and revokeObjectURL
    const originalCreateObjectURL = URL.createObjectURL
    const originalRevokeObjectURL = URL.revokeObjectURL
    URL.createObjectURL = vi.fn().mockReturnValue('blob:test')
    URL.revokeObjectURL = revokeUrl

    // Mock createElement to return a controllable anchor
    const mockAnchor = { click: mockClick, href: '', download: '' }
    mockCreateElement.mockReturnValue(mockAnchor)

    downloadFile('csv,data,here', 'export.csv', 'text/csv')

    expect(URL.createObjectURL).toHaveBeenCalled()
    expect(mockClick).toHaveBeenCalled()
    expect(mockAnchor.download).toBe('export.csv')

    // Cleanup
    URL.createObjectURL = originalCreateObjectURL
    URL.revokeObjectURL = originalRevokeObjectURL
    mockCreateElement.mockRestore()
  })
})

// ── uploadToStorage ─────────────────────────────────────────────────────────

describe('uploadToStorage', () => {
  it('uploads file and returns public URL', async () => {
    const mockUpload = vi
      .fn()
      .mockResolvedValue({ data: { path: 'models/test.tflite' }, error: null })
    const mockGetPublicUrl = vi.fn().mockReturnValue({
      data: { publicUrl: 'https://storage.test/models/test.tflite' },
    })

    const mockSupabase = {
      storage: {
        from: vi.fn().mockReturnValue({
          upload: mockUpload,
          getPublicUrl: mockGetPublicUrl,
        }),
      },
    }

    const file = new Blob(['model bytes'], { type: 'application/octet-stream' })
    const url = await uploadToStorage(
      mockSupabase,
      'models',
      'models/test.tflite',
      file
    )

    expect(url).toBe('https://storage.test/models/test.tflite')
    expect(mockUpload).toHaveBeenCalledWith('models/test.tflite', file, {
      cacheControl: '3600',
      upsert: true,
      contentType: 'application/octet-stream',
    })
  })

  it('throws on upload error', async () => {
    const mockSupabase = {
      storage: {
        from: vi.fn().mockReturnValue({
          upload: vi.fn().mockResolvedValue({
            data: null,
            error: { message: 'Bucket full' },
          }),
        }),
      },
    }

    const file = new Blob(['data'])
    await expect(
      uploadToStorage(mockSupabase, 'models', 'path', file)
    ).rejects.toThrow('Bucket full')
  })
})

// ── ensureBucket ────────────────────────────────────────────────────────────

describe('ensureBucket', () => {
  it('creates bucket without error', async () => {
    const mockSupabase = {
      storage: {
        createBucket: vi.fn().mockResolvedValue({ error: null }),
      },
    }

    await ensureBucket(mockSupabase, 'test-bucket')
    expect(mockSupabase.storage.createBucket).toHaveBeenCalledWith(
      'test-bucket',
      { public: true }
    )
  })

  it('ignores "already exists" error', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const mockSupabase = {
      storage: {
        createBucket: vi.fn().mockResolvedValue({
          error: { message: 'Bucket already exists' },
        }),
      },
    }

    // Should not throw
    await expect(
      ensureBucket(mockSupabase, 'existing-bucket')
    ).resolves.toBeUndefined()

    // Should NOT log warning for "already exists"
    expect(consoleSpy).not.toHaveBeenCalled()
    consoleSpy.mockRestore()
  })

  it('logs warning for other errors', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const mockSupabase = {
      storage: {
        createBucket: vi.fn().mockResolvedValue({
          error: { message: 'Permission denied' },
        }),
      },
    }

    await ensureBucket(mockSupabase, 'forbidden-bucket')
    expect(consoleSpy).toHaveBeenCalledWith('Bucket:', 'Permission denied')
    consoleSpy.mockRestore()
  })
})
