import api from "./axios";

export const apiService = {
  login: async (username: string, password: string) => {
    const response = await api.post("/auth/login", { username, password });
    return response.data;
  },
  fetchUserData: async (token: string) => {
    const response = await api.post(
      "/users/me",
      {},
      {
        headers: { Authorization: `Bearer ${token}` },
      }
    );
    return response.data;
  },
  fetchAllAccounts: async (token: string) => {
    const response = await api.get("/accounts/all", {
      headers: { Authorization: `Bearer ${token}` },
    });
    return response.data;
  },
  fetchTransactions: async (token: string, accountId: string) => {
    const response = await api.get(`/transactions/history/${accountId}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    return response.data;
  },
  createAccount: async (token: string, initialBalance: number) => {
    const response = await api.post(
      "/accounts",
      { initialBalance },
      {
        headers: { Authorization: `Bearer ${token}` },
      }
    );
    return response.data;
  },
  deposit: async (token: string, accountId: string, amount: number) => {
    const response = await api.post(
      "/transactions/deposit",
      { accountId, amount },
      {
        headers: { Authorization: `Bearer ${token}` },
      }
    );
    return response.data;
  },
  withdraw: async (token: string, accountId: string, amount: number) => {
    const response = await api.post(
      "/transactions/withdraw",
      { accountId, amount },
      {
        headers: { Authorization: `Bearer ${token}` },
      }
    );
    return response.data;
  },
  transfer: async (
    token: string,
    fromAccountId: number,
    toAccountId: number,
    amount: number
  ) => {
    const response = await api.post(
      "/transactions/transfer",
      { fromAccountId, toAccountId, amount },
      {
        headers: { Authorization: `Bearer ${token}` },
      }
    );
    return response.data;
  },
};
