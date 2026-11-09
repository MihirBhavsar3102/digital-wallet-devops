import React, { useState } from "react";
import { toast } from "react-toastify";
import { useAuth } from "../context/AuthContext";

const NoAccountsMessage: React.FC = () => {
  const { user, addAccount } = useAuth();
  const [initialBalance, setInitialBalance] = useState<number | "">("");

  const handleAddAccount = async () => {
    if (typeof initialBalance === "number" && initialBalance > 0) {
      await addAccount(initialBalance);
      setInitialBalance("");
    } else {
      toast.error("Please enter a valid initial balance.");
    }
  };

  return (
    <div className="flex justify-center items-center min-h-screen bg-gradient-to-r from-gray-100 to-gray-200">
      <div className="p-8 bg-white rounded-lg shadow-lg max-w-md">
        <h2 className="text-2xl font-bold mb-4 text-gray-800">
          Welcome, {user?.username}!
        </h2>
        <p className="mb-4 text-gray-600">
          It looks like you don’t have any accounts yet.
        </p>
        <input
          type="number"
          placeholder="Initial Balance"
          value={initialBalance}
          onChange={(e) => setInitialBalance(Number(e.target.value))}
          className="p-2 border rounded w-full mb-4 focus:outline-none focus:ring-2 focus:ring-blue-400"
        />
        <button
          onClick={handleAddAccount}
          className="w-full p-3 bg-blue-500 font-medium shadow-md hover:bg-blue-600 text-white rounded-lg transition"
        >
          Create First Account
        </button>
      </div>
    </div>
  );
};

export default NoAccountsMessage;
