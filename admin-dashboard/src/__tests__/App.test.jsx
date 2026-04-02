import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

// ── Mock the Supabase client before any component import ────────────────────
// vi.mock hoists automatically, so the mock is in place when App first loads.
const mockSubscription = { unsubscribe: vi.fn() }

const mockGetSession = vi.fn()
const mockOnAuthStateChange = vi.fn(() => ({
  data: { subscription: mockSubscription },
}))
const mockSignOut = vi.fn(() => Promise.resolve())

const mockSingle = vi.fn()
const mockEq = vi.fn(() => ({ single: mockSingle }))
const mockSelect = vi.fn(() => ({ eq: mockEq }))
const mockFrom = vi.fn(() => ({ select: mockSelect }))

vi.mock('../lib/supabase', () => ({
  supabase: {
    auth: {
      getSession: (...args) => mockGetSession(...args),
      onAuthStateChange: (...args) => mockOnAuthStateChange(...args),
      signInWithPassword: vi.fn(() => Promise.resolve({ error: null })),
      signOut: (...args) => mockSignOut(...args),
    },
    from: (...args) => mockFrom(...args),
  },
}))

// ── Mock recharts to avoid canvas/SVG issues in jsdom ───────────────────────
vi.mock('recharts', () => ({
  AreaChart: ({ children }) => children,
  Area: () => null,
  BarChart: ({ children }) => children,
  Bar: () => null,
  XAxis: () => null,
  YAxis: () => null,
  CartesianGrid: () => null,
  Tooltip: () => null,
  ResponsiveContainer: ({ children }) => children,
  Cell: () => null,
}))

import App from '../App'

// ── Helpers ─────────────────────────────────────────────────────────────────

function renderApp(route = '/') {
  return render(
    <MemoryRouter initialEntries={[route]}>
      <App />
    </MemoryRouter>,
  )
}

function fakeSession(email = 'admin@test.com') {
  return {
    user: { id: 'user-123', email },
    access_token: 'fake-token',
  }
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe('App smoke tests', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // Default: no session
    mockGetSession.mockResolvedValue({ data: { session: null } })
    mockSingle.mockResolvedValue({ data: null, error: null })
  })

  it('renders login page when no session', async () => {
    renderApp()

    // LoginPage contains "Welcome back"
    await waitFor(() => {
      expect(screen.getByText('Welcome back')).toBeInTheDocument()
    })

    expect(screen.getByText('Sign in to access the admin dashboard')).toBeInTheDocument()
    expect(screen.getByPlaceholderText('admin@example.com')).toBeInTheDocument()
  })

  it('shows access denied for non-admin user', async () => {
    const session = fakeSession('user@test.com')
    mockGetSession.mockResolvedValue({ data: { session } })

    // Profile query returns a non-admin role
    mockSingle.mockResolvedValue({
      data: { role: 'user', is_active: true, email: 'user@test.com' },
      error: null,
    })

    renderApp()

    await waitFor(() => {
      expect(screen.getByText('Access Denied')).toBeInTheDocument()
    })

    expect(
      screen.getByText(/does not have administrator privileges/),
    ).toBeInTheDocument()
  })

  it('renders dashboard layout for admin user', async () => {
    const session = fakeSession('admin@test.com')
    mockGetSession.mockResolvedValue({ data: { session } })

    // Profile query returns admin role
    mockSingle.mockResolvedValue({
      data: { role: 'admin', is_active: true, email: 'admin@test.com' },
      error: null,
    })

    renderApp('/')

    // Layout renders the brand name "AgriKD" and sidebar nav items
    await waitFor(() => {
      expect(screen.getByText('AgriKD')).toBeInTheDocument()
    })

    // Verify sidebar navigation items are present (use getAllByText because
    // "Dashboard" appears both in the sidebar nav and the page heading)
    expect(screen.getAllByText('Dashboard').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('Predictions')).toBeInTheDocument()
    expect(screen.getByText('Settings')).toBeInTheDocument()
    expect(screen.getByText('Sign Out')).toBeInTheDocument()
  })
})
