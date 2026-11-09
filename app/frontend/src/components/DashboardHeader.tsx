import React from "react";
import { useAuth } from "../context/AuthContext";

const DashboardHeader: React.FC = () => {
  const { user, logout } = useAuth();

  return (
    <header className="flex justify-between items-center mb-6">
      <h1 className="text-3xl font-bold text-gray-800">
        Welcome, {user?.username}!
      </h1>
      <button
        onClick={logout}
        className="p-3 px-6 bg-gradient-to-r from-red-500 to-red-600 text-white rounded-lg hover:from-red-600 hover:to-red-700 shadow-md hover:shadow-lg transition-transform transform hover:scale-105"
      >
        Logout
      </button>
    </header>
  );
};

export default DashboardHeader;
