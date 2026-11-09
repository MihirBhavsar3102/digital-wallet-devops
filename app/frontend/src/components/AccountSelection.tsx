import React, { useState } from "react";
import { useAuth } from "../context/AuthContext";

const AccountSelection: React.FC = () => {
  const { user, currentAccount, switchAccount, addAccount } = useAuth();

  const [initialBalance, setInitialBalance] = useState<number | "">("");

  const handleAddAccount = async () => {
    if (typeof initialBalance === "number" && initialBalance > 0) {
      await addAccount(initialBalance);
      setInitialBalance("");
    } else {
      alert("Please enter a valid initial balance.");
    }
  };

  if (!user) {
    return <p className="text-center text-gray-600">Loading user data...</p>;
  }

  return (
    <div className="mb-6">
      <h2 className="text-xl font-semibold text-gray-700">Select Account</h2>
      <div className="flex flex-wrap gap-4 mt-4 justify-between">
        <div className="flex items-center gap-3">
          {user.accounts.map((account) => (
            <button
              key={account.id}
              onClick={() => switchAccount(account.id)}
              className={`px-4 py-2 rounded-lg font-medium transition ${
                account.id === currentAccount?.id
                  ? "bg-blue-500 text-white"
                  : "bg-gray-200 text-gray-800 hover:bg-gray-300"
              }`}
            >
              Account #{account.id}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-3">
          <input
            type="number"
            placeholder="Initial Balance"
            className="p-3 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-400"
            value={initialBalance}
            onChange={(e) => setInitialBalance(Number(e.target.value))}
          />
          <button
            onClick={handleAddAccount}
            className="px-4 py-2 bg-blue-500 text-white font-medium rounded-lg shadow-md hover:bg-blue-600 transition"
          >
            + Add Account
          </button>
        </div>
      </div>
    </div>
  );
};

export default AccountSelection;
