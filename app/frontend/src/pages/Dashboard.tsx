import React, { useEffect } from "react";
import { useAuth } from "../context/AuthContext";
import { useNavigate } from "react-router-dom";
import AccountSelection from "../components/AccountSelection";
import TransactionActions from "../components/TransactionActions";
import TransactionHistory from "../components/TransactionHistory";
import DashboardHeader from "../components/DashboardHeader";
import CurrentAccountBalance from "../components/CurrentAccountBalance";
import NoAccountsMessage from "../components/NoAccountsMessage";

const Dashboard: React.FC = () => {
  const { user, currentAccount } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    if (!user) {
      navigate("/");
    }
  }, [user, navigate]);

  if (!user) {
    return <p className="text-center text-gray-600">Loading...</p>;
  }
  if (!currentAccount) {
    return <NoAccountsMessage />;
  }
  return (
    <div className="flex justify-center min-h-screen bg-gradient-to-r from-gray-50 to-gray-200 pt-10">
      <div className="w-full max-w-5xl p-8 bg-white rounded-lg shadow-lg">
        <DashboardHeader />
        <AccountSelection />
        <CurrentAccountBalance />
        <TransactionActions />
        <TransactionHistory />
      </div>
    </div>
  );
};

export default Dashboard;
