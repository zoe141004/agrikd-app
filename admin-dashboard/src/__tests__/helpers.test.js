import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

import {
  cleanLabel,
  maskUrl,
  formatDateTime,
  formatBytes,
  validateGitHubSlugs,
  checkRateLimit,
} from '../lib/helpers'

// ── cleanLabel ──────────────────────────────────────────────────────────────

describe('cleanLabel', () => {
  it('strips Tomato___ prefix and replaces underscores with spaces', () => {
    expect(cleanLabel('Tomato___Bacterial_spot')).toBe('Bacterial spot')
  })

  it('strips any genus prefix before ___', () => {
    expect(cleanLabel('BurmeseGrape___Anthracnose')).toBe('Anthracnose')
  })

  it('handles labels with no prefix', () => {
    expect(cleanLabel('Healthy')).toBe('Healthy')
  })

  it('handles underscores without prefix', () => {
    expect(cleanLabel('Early_blight')).toBe('Early blight')
  })

  it('returns Unknown for null', () => {
    expect(cleanLabel(null)).toBe('Unknown')
  })

  it('returns Unknown for undefined', () => {
    expect(cleanLabel(undefined)).toBe('Unknown')
  })

  it('returns Unknown for empty string', () => {
    expect(cleanLabel('')).toBe('Unknown')
  })
})

// ── maskUrl ─────────────────────────────────────────────────────────────────

describe('maskUrl', () => {
  it('masks a valid URL to protocol + truncated hostname', () => {
    const result = maskUrl('https://myproject.supabase.co/storage/v1/object/photo.jpg')
    // hostname "myproject.supabase.co".slice(0,8) = "myprojec"
    expect(result).toBe('https://myprojec\u2026')
  })

  it('returns dash for null', () => {
    expect(maskUrl(null)).toBe('—')
  })

  it('returns dash for undefined', () => {
    expect(maskUrl(undefined)).toBe('—')
  })

  it('truncates invalid URL to first 22 chars', () => {
    const badUrl = 'not-a-real-url-but-a-very-long-string'
    expect(maskUrl(badUrl)).toBe('not-a-real-url-but-a-v\u2026')
  })
})

// ── formatDateTime ──────────────────────────────────────────────────────────

describe('formatDateTime', () => {
  it('returns dash for null', () => {
    expect(formatDateTime(null)).toBe('—')
  })

  it('returns dash for undefined', () => {
    expect(formatDateTime(undefined)).toBe('—')
  })

  it('returns a formatted date string for valid ISO input', () => {
    const result = formatDateTime('2026-03-20T10:00:00Z')
    // Result is locale-dependent, but should be a non-empty string
    expect(result).toBeTruthy()
    expect(result).not.toBe('—')
    // Should contain "2026" somewhere
    expect(result).toContain('2026')
  })
})

// ── formatBytes ─────────────────────────────────────────────────────────────

describe('formatBytes', () => {
  it('returns 0 B for null', () => {
    expect(formatBytes(null)).toBe('0 B')
  })

  it('returns 0 B for 0', () => {
    expect(formatBytes(0)).toBe('0 B')
  })

  it('formats bytes', () => {
    expect(formatBytes(500)).toBe('500.0 B')
  })

  it('formats kilobytes', () => {
    expect(formatBytes(1024)).toBe('1.0 KB')
  })

  it('formats megabytes', () => {
    expect(formatBytes(1048576)).toBe('1.0 MB')
  })

  it('formats gigabytes', () => {
    expect(formatBytes(1073741824)).toBe('1.0 GB')
  })

  it('formats fractional MB', () => {
    expect(formatBytes(5242880)).toBe('5.0 MB')
  })
})

// ── validateGitHubSlugs ─────────────────────────────────────────────────────

describe('validateGitHubSlugs', () => {
  it('accepts valid owner and repo', () => {
    expect(() => validateGitHubSlugs('my-org', 'my-repo')).not.toThrow()
  })

  it('accepts names with dots and underscores', () => {
    expect(() => validateGitHubSlugs('my_org.io', 'repo.v2')).not.toThrow()
  })

  it('throws for owner with slashes (path traversal)', () => {
    expect(() => validateGitHubSlugs('../../etc', 'repo')).toThrow('Invalid GitHub owner')
  })

  it('throws for repo with spaces', () => {
    expect(() => validateGitHubSlugs('owner', 'my repo')).toThrow('Invalid GitHub repo')
  })

  it('throws for empty owner', () => {
    expect(() => validateGitHubSlugs('', 'repo')).toThrow('Invalid GitHub owner')
  })

  it('throws for empty repo', () => {
    expect(() => validateGitHubSlugs('owner', '')).toThrow('Invalid GitHub repo')
  })

  it('throws for owner exceeding 100 chars', () => {
    const long = 'a'.repeat(101)
    expect(() => validateGitHubSlugs(long, 'repo')).toThrow('Invalid GitHub owner')
  })

  it('throws for owner with special characters', () => {
    expect(() => validateGitHubSlugs('owner<script>', 'repo')).toThrow('Invalid GitHub owner')
  })
})

// ── checkRateLimit ──────────────────────────────────────────────────────────

describe('checkRateLimit', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('returns a stamp function on first call', () => {
    const stamp = checkRateLimit('test-action', 30000)
    expect(typeof stamp).toBe('function')
  })

  it('throws when called within cooldown window', () => {
    const stamp = checkRateLimit('test-action', 30000)
    stamp() // Set the timestamp

    expect(() => checkRateLimit('test-action', 30000)).toThrow(/Please wait/)
  })

  it('allows call after cooldown expires', () => {
    const stamp = checkRateLimit('test-action', 5000)
    stamp()

    vi.advanceTimersByTime(6000)

    expect(() => checkRateLimit('test-action', 5000)).not.toThrow()
  })

  it('uses different keys independently', () => {
    const stamp1 = checkRateLimit('action-a', 30000)
    stamp1()

    // Different key should not be rate-limited
    expect(() => checkRateLimit('action-b', 30000)).not.toThrow()
  })

  it('error message includes remaining seconds', () => {
    const stamp = checkRateLimit('test-action', 30000)
    stamp()

    vi.advanceTimersByTime(10000) // 10s elapsed, 20s remaining

    try {
      checkRateLimit('test-action', 30000)
      expect.fail('Should have thrown')
    } catch (err) {
      expect(err.message).toMatch(/20s/)
    }
  })
})
