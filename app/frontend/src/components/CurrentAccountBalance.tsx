import React from "react";
import { useAuth } from "../context/AuthContext";

const CurrentAccountBalance: React.FC = () => {
  const { currentAccount } = useAuth();

  if (!currentAccount) {
    return null;
  }

  return (
    <div className="p-6 bg-gray-100 rounded-lg shadow-md">
      <h2 className="text-xl font-semibold mb-4 text-gray-700">
        Current Account Balance
      </h2>
      <p className="text-2xl font-bold text-gray-800">
        ${currentAccount.balance.toFixed(2)}
      </p>
    </div>
  );
};

export default CurrentAccountBalance;
