import React from "react";
import { Search, Sparkles } from "lucide-react";
import { displayPetValue } from "./format";

export function PetIcon({ pet, size = "medium", variant = "normal" }) {
  const source = variant === "golden" && pet?.goldenThumbnailUrl ? pet.goldenThumbnailUrl : pet?.thumbnailUrl;
  const fallback = variant === "golden" ? (pet?.goldenThumbnail || pet?.thumbnail) : pet?.thumbnail;
  return <div className={`pet-icon pet-icon-${size}`}>
    {source ? <img src={source} alt={pet?.name || "Pet"} loading="lazy" decoding="async" onError={(e) => {
      const id = String(fallback || "").replace(/^rbxassetid:\/\//i, "");
      const direct = id ? `https://ps99.biggamesapi.io/image/${id}` : "";
      if (direct && e.currentTarget.src !== direct) e.currentTarget.src = direct; else e.currentTarget.style.display = "none";
    }} /> : <div className="pet-placeholder"><Sparkles size={18}/></div>}
  </div>;
}

export function tierOf(pet) {
  const s = `${pet?.category || ""} ${pet?.name || ""}`.toLowerCase();
  if (s.includes("gargantuan")) return "GARGANTUAN";
  if (s.includes("titanic")) return "TITANIC";
  if (s.includes("huge")) return "HUGE";
  return "";
}

export function PetCard({ pet, value, onClick, showRap = false, locked = false }) {
  const tier = tierOf(pet);
  return <button className={`pet-card ${locked ? "pet-locked" : ""}`} onClick={locked ? undefined : onClick} disabled={locked}>
    <div className="pet-card-image"><PetIcon pet={pet} size="large"/>{tier && <span className={`pet-tag ${tier.toLowerCase()}`}>{tier}</span>}</div>
    <div className="pet-card-name" title={pet.name}>{pet.name}</div>
    <div className="pet-card-value">{locked ? "NOT PRICED" : (Number(value||0)>0 ? <>💎 {displayPetValue(value)}</> : "NOT PRICED")}</div>
    {showRap && <div className="pet-card-meta">PS99 RAP</div>}
  </button>;
}

export function PoolCard({ pet, value, selected, onToggle }) {
  const tier = tierOf(pet); const locked = false;
  return <button className={`pool-card ${selected ? "selected" : ""} ${locked ? "pool-locked" : ""}`} onClick={locked ? undefined : onToggle} disabled={locked}>
    <div className="pool-image"><PetIcon pet={pet} size="medium"/>{tier && <span className="pool-tier">{tier}</span>}</div>
    <div className="pool-name" title={pet.name}>{pet.name}</div>
    <div className="pool-value">{locked ? "NOT PRICED" : (Number(value||0)>0 ? <>💎 {displayPetValue(value)}</> : "NOT PRICED")}</div>
    <div className="pool-sub">PS99 RAP</div>
    {selected && <div className="owned-badge">✓ selected</div>}
  </button>;
}

export function SearchBox({ value, onChange, placeholder = "Search..." }) {
  return <div className="search-box"><Search size={16}/><input value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}/></div>;
}

export function Modal({ children, onClose, className = "" }) {
  return <div className="modal-backdrop" onMouseDown={onClose}><div className={`modal ${className}`.trim()} onMouseDown={e => e.stopPropagation()}>{children}</div></div>;
}
