/* eslint-disable @typescript-eslint/no-explicit-any */
import React, {
  createContext,
  useState,
  useContext,
  ReactNode,
  useEffect,
} from "react";
import { toast } from "react-toastify";
import { apiService } from "../services/apiService";

interface Account {
  id: string;
  balance: number;
}

interface User {
  id: string;
  username: string;
  email: string;
  accounts: Account[];
}

interface AccountDetails {
  id: number;
  userId: number;
  balance: number;
  user: {
    username: string;
  };
}

interface Transaction {
  id: number;
  fromAccountId: number;
  toAccountId: number;
  type: "TRANSFER" | "DEPOSIT" | "WITHDRAWAL";
  amount: number;
  status: "SUCCESS" | "FAILURE";
  createdAt: string;
}

interface AuthContextProps {
  user: User | null;
  currentAccount: Account | null;
  allAccounts: AccountDetails[];
  switchAccount: (accountId: string) => void;
  login: (email: string, password: string) => Promise<void>;
  logout: () => void;
  deposit: (amount: number) => Promise<void>;
  withdraw: (amount: number) => void;
  transfer: (
    recipientId: number,
    amount: number,
    senderAccountId: number
  ) => void;
  addAccount: (initialBalance: number) => Promise<void>;
  transactions: Transaction[];
}

const AuthContext = createContext<AuthContextProps | undefined>(undefined);

export const AuthProvider: React.FC<{ children: ReactNode }> = ({
  children,
}) => {
  const [user, setUser] = useState<User | null>(null);
  const [currentAccount, setCurrentAccount] = useState<Account | null>(null);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [allAccounts, setAllAccounts] = useState<AccountDetails[]>([]);

  const login = async (username: string, password: string) => {
    try {
      const { access_token } = await apiService.login(username, password);
      localStorage.setItem("token", access_token);

      const userData = await apiService.fetchUserData(access_token);
      setUser({
        id: userData.id,
        username: userData.username,
        email: userData.email,
        accounts: userData.accounts,
      });

      if (userData.accounts?.length > 0) {
        setCurrentAccount(userData.accounts[0]);
      }

      const accounts = await apiService.fetchAllAccounts(access_token);
      setAllAccounts(accounts);
    } catch (error: any) {
      throw new Error(
        (error.response?.data?.message as string) || "Login failed"
      );
    }
  };

  const logout = () => {
    localStorage.removeItem("token");
    setUser(null);
    setCurrentAccount(null);
    setAllAccounts([]);
  };

  const switchAccount = (accountId: string) => {
    if (user) {
      const account = user.accounts.find((acc) => acc.id === accountId);
      if (account) setCurrentAccount(account);
    }
  };

  const addAccount = async (initialBalance: number) => {
    try {
      const token = localStorage.getItem("token")!;
      const newAccount = await apiService.createAccount(token, initialBalance);

      if (user) {
        const updatedAccounts = [...user.accounts, newAccount];
        setUser({ ...user, accounts: updatedAccounts });
        setCurrentAccount(newAccount);
      }
      const accounts = await apiService.fetchAllAccounts(token);
      setAllAccounts(accounts);
      toast.success("Account added successfully!");
    } catch (error: any) {
      toast.error(error.response?.data?.message || "Failed to add account.");
    }
  };

  const deposit = async (amount: number) => {
    if (!currentAccount) {
      toast.error("No account selected.");
      return;
    }

    try {
      const token = localStorage.getItem("token")!;
      const depositData = await apiService.deposit(
        token,
        currentAccount.id,
        amount
      );

      const newBalance = depositData.amount + currentAccount.balance;
      setCurrentAccount({ ...currentAccount, balance: newBalance });

      if (user) {
        const updatedAccounts = user.accounts.map((acc) =>
          acc.id === currentAccount.id ? { ...acc, balance: newBalance } : acc
        );
        setUser({ ...user, accounts: updatedAccounts });
      }

      toast.success("Deposit successful!");
      fetchTransactions(currentAccount.id);
    } catch (error: any) {
      toast.error(error.response?.data?.message || "Deposit failed.");
    }
  };

  const withdraw = async (amount: number) => {
    try {
      if (currentAccount && currentAccount.balance >= amount) {
        const token = localStorage.getItem("token")!;
        const response = await apiService.withdraw(
          token,
          currentAccount.id,
          amount
        );

        const newBalance = currentAccount.balance - response.amount;
        setCurrentAccount({ ...currentAccount, balance: newBalance });

        if (user) {
          const updatedAccounts = user.accounts.map((acc) =>
            acc.id === currentAccount.id ? { ...acc, balance: newBalance } : acc
          );
          setUser({ ...user, accounts: updatedAccounts });
        }

        toast.success("Withdrawal successful!");
        fetchTransactions(currentAccount.id);
      } else {
        toast.error("Insufficient balance.");
      }
    } catch (error: any) {
      toast.error(error.response?.data?.message || "Withdrawal failed.");
    }
  };

  const transfer = async (
    recipientId: number,
    amount: number,
    senderAccountId: number
  ) => {
    if (currentAccount && currentAccount.balance >= amount) {
      try {
        const token = localStorage.getItem("token")!;
        await apiService.transfer(token, senderAccountId, recipientId, amount);

        const newSenderBalance = currentAccount.balance - amount;

        setCurrentAccount({ ...currentAccount, balance: newSenderBalance });

        if (user) {
          const updatedAccounts = user.accounts.map((acc) => {
            if (acc.id === currentAccount.id) {
              return { ...acc, balance: newSenderBalance };
            } else if (Number(acc.id) === recipientId) {
              return { ...acc, balance: acc.balance + amount };
            }
            return acc;
          });

          setUser({ ...user, accounts: updatedAccounts });
        }
        toast.success("Transfer successful!");
        fetchTransactions(currentAccount.id);
      } catch (error: any) {
        toast.error(error.response?.data?.message || "Transfer failed.");
      }
    } else {
      toast.error("Insufficient funds.");
    }
  };

  const fetchTransactions = async (accountId: string) => {
    try {
      const token = localStorage.getItem("token")!;
      const data = await apiService.fetchTransactions(token, accountId);
      setTransactions(data);
    } catch (error: any) {
      toast.error(
        error.response?.data?.message || "Failed to fetch transactions."
      );
    }
  };

  useEffect(() => {
    if (currentAccount) fetchTransactions(currentAccount.id);
  }, [currentAccount]);

  return (
    <AuthContext.Provider
      value={{
        user,
        currentAccount,
        allAccounts,
        switchAccount,
        login,
        logout,
        deposit,
        withdraw,
        transfer,
        addAccount,
        transactions,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error("useAuth must be used within an AuthProvider");
  }
  return context;
};
