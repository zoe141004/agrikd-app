import { vi } from 'vitest'

// Default resolved values (override per-test via mockResolvedValueOnce)
let _getSessionResult = { data: { session: null } }
let _profileQueryResult = { data: null, error: null }

const mockSubscription = { unsubscribe: vi.fn() }

const supabase = {
  auth: {
    getSession: vi.fn(() => Promise.resolve(_getSessionResult)),
    onAuthStateChange: vi.fn(() => ({
      data: { subscription: mockSubscription },
    })),
    signInWithPassword: vi.fn(() => Promise.resolve({ error: null })),
    signOut: vi.fn(() => Promise.resolve()),
  },
  from: vi.fn(() => ({
    select: vi.fn().mockReturnThis(),
    eq: vi.fn().mockReturnThis(),
    single: vi.fn(() => Promise.resolve(_profileQueryResult)),
  })),
}

/**
 * Helper to configure what getSession resolves to.
 * Call before rendering the component under test.
 */
export function __mockGetSession(session) {
  _getSessionResult = { data: { session } }
  supabase.auth.getSession.mockReturnValue(Promise.resolve(_getSessionResult))
}

/**
 * Helper to configure what the profiles query resolves to.
 */
export function __mockProfileQuery(data, error = null) {
  _profileQueryResult = { data, error }
  // Rebuild the from() chain so the new result is picked up
  const chain = {
    select: vi.fn().mockReturnThis(),
    eq: vi.fn().mockReturnThis(),
    single: vi.fn(() => Promise.resolve(_profileQueryResult)),
  }
  // Make each chained method return the chain itself
  chain.select.mockReturnValue(chain)
  chain.eq.mockReturnValue(chain)
  supabase.from.mockReturnValue(chain)
}

/**
 * Reset all mocks to defaults between tests.
 */
export function __resetMocks() {
  _getSessionResult = { data: { session: null } }
  _profileQueryResult = { data: null, error: null }
  supabase.auth.getSession.mockReset()
  supabase.auth.getSession.mockReturnValue(Promise.resolve(_getSessionResult))
  supabase.auth.onAuthStateChange.mockReturnValue({
    data: { subscription: mockSubscription },
  })
  supabase.auth.signInWithPassword.mockReset()
  supabase.auth.signOut.mockReset()
  supabase.from.mockReset()
}

export { supabase }
