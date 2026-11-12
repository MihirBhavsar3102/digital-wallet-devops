// Traffic for the monitoring: a realistic mix of requests against the load balancer, so that every panel of the
// dashboards moves and the alarms can be tried with real load. Run by scripts/load/run.sh (README, "Load test").
//
// What each iteration does, picked by weight: load the page, read balances, deposit, transfer between the user's
// two accounts, read the history; and, on purpose, a request for a path that does not exist (404), one without
// a token (401) and a login with a wrong password (401). With ERROR_PERCENT above 0, that share of the requests
// is instead a deliberate server error: POST /api/auth/login with an empty body makes Prisma throw, so the backend
// answers 500 and logs two error lines, with no debug route in the application.
//
// Settings (environment): BASE_URL (required, http://<load balancer>), RATE (requests per second, default 10),
// DURATION (default 5m), ERROR_PERCENT (default 0), USERS (default 5).
//
// Every request has an expected status, and the run counts how often the application answered something else.
// Only a 5xx is a failure to k6 here: a 404 or 401 that was asked for is exactly what the test wants.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE_URL;
const RATE = Number(__ENV.RATE || 10);
const DURATION = __ENV.DURATION || '5m';
const ERROR_PERCENT = Number(__ENV.ERROR_PERCENT || 0);
const USERS = Number(__ENV.USERS || 5);
if (!BASE) throw new Error('BASE_URL is required, for example http://my-load-balancer.example.com');

// Only 5xx counts as "failed" in k6's own http_req_failed: the 404s and 401s below are expected.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

const unexpected = new Counter('unexpected_status');

export const options = {
  scenarios: {
    traffic: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
};

const json = { headers: { 'Content-Type': 'application/json' } };
const withToken = (token) => ({ headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` } });

// Runs once: a few users, each logged in and with two accounts, so that deposits and transfers have something to move.
export function setup() {
  const run = Date.now();
  const users = [];
  for (let i = 0; i < USERS; i++) {
    const username = `load_${run}_${i}`;
    const password = 'Passw0rd!';
    const reg = http.post(`${BASE}/api/users/register`, JSON.stringify({ username, email: `${username}@example.com`, password }), json);
    const login = http.post(`${BASE}/api/auth/login`, JSON.stringify({ username, password }), json);
    if (reg.status !== 201 || login.status !== 200) throw new Error(`setup failed for ${username}: register ${reg.status}, login ${login.status}`);
    const token = login.json('access_token');
    const accounts = [1, 2].map(() => http.post(`${BASE}/api/accounts`, JSON.stringify({ initialBalance: 100000 }), withToken(token)).json('id'));
    users.push({ username, password, accounts });
  }
  return { users };
}

// The application's login tokens last 300 seconds (auth.module.ts). A token taken once in setup() would run out
// five minutes into the test and every authenticated request after that would be a 401, so each virtual user logs
// in itself and takes a fresh token after 4 minutes. (The first baseline run ended exactly at 5 minutes and showed
// five 401s for this reason.)
const TOKEN_MAX_AGE_MS = 240 * 1000;
const sessions = {}; // one per virtual user: username -> { token, takenAt }
function tokenFor(user) {
  const known = sessions[user.username];
  if (known && Date.now() - known.takenAt < TOKEN_MAX_AGE_MS) return known.token;
  const res = http.post(`${BASE}/api/auth/login`, JSON.stringify({ username: user.username, password: user.password }), json);
  if (res.status !== 200) return known ? known.token : '';
  sessions[user.username] = { token: res.json('access_token'), takenAt: Date.now() };
  return sessions[user.username].token;
}

// Each entry: a weight, and what to do. Every one says which status it expects.
function scenarios(user) {
  const [a, b] = user.accounts;
  const auth = withToken(tokenFor(user));
  return [
    { w: 40, name: 'page', expect: 200, run: () => http.get(`${BASE}/`) },
    { w: 20, name: 'balances', expect: 200, run: () => http.get(`${BASE}/api/accounts/my-accounts`, auth) },
    { w: 10, name: 'deposit', expect: 201, run: () => http.post(`${BASE}/api/transactions/deposit`, JSON.stringify({ accountId: a, amount: 1 + Math.floor(Math.random() * 20) }), auth) },
    { w: 5, name: 'transfer', expect: 201, run: () => http.post(`${BASE}/api/transactions/transfer`, JSON.stringify({ fromAccountId: a, toAccountId: b, amount: 1 }), auth) },
    { w: 5, name: 'history', expect: 200, run: () => http.get(`${BASE}/api/transactions/history/${a}`, auth) },
    { w: 7, name: 'not found', expect: 404, run: () => http.get(`${BASE}/api/no-such-route`) },
    { w: 7, name: 'no token', expect: 401, run: () => http.get(`${BASE}/api/accounts/my-accounts`) },
    { w: 6, name: 'wrong password', expect: 401, run: () => http.post(`${BASE}/api/auth/login`, JSON.stringify({ username: 'nobody', password: 'wrong' }), json) },
  ];
}

export default function (data) {
  // The deliberate failure replaces a request, so ERROR_PERCENT is the share of all requests that are a 5xx.
  if (ERROR_PERCENT > 0 && Math.random() * 100 < ERROR_PERCENT) {
    const res = http.post(`${BASE}/api/auth/login`, '{}', json);
    if (!check(res, { 'deliberate error is a 500': (r) => r.status === 500 })) unexpected.add(1);
    return;
  }
  const user = data.users[Math.floor(Math.random() * data.users.length)];
  const list = scenarios(user);
  const total = list.reduce((sum, s) => sum + s.w, 0);
  let pick = Math.random() * total;
  const chosen = list.find((s) => (pick -= s.w) < 0) || list[0];
  const res = chosen.run();
  if (!check(res, { [`${chosen.name} answers ${chosen.expect}`]: (r) => r.status === chosen.expect })) unexpected.add(1);
}
