<img width="1024" height="1024" alt="hashwall-avatar-2k (dev:sources)" src="https://github.com/user-attachments/assets/248d13fe-e789-41e7-a74e-5733074699be" />
# hashwall-vanity
Hashwall: The Identity &amp; Security Layer for Multi-chain Assets. High-performance infrastructure for secure multisig vanity addresses. 


Opensourced for Solana Colosseum Hackathon, leveraging GPU acceleration to solve the R&D bottlenecks of traditional security & customization approaches.

Hashwall is a specialized infrastructure for secure, branded multisig vanity addresses on Solana. Built specifically for the Solana Colosseum Hackathon, it leverages GPU acceleration to solve the R&D bottlenecks of traditional address generation.

## 🚀 The Core: GPU-Accelerated Engine
Unlike standard CPU-based tools, Hashwall utilizes a **proprietary CUDA-optimized engine** to achieve massive parallelization in address generation. 
*   **Performance:** Optimized for `ed25519` curve vanity search.
*   *   **Performance:** Optimized for `SHA-512` hashing algorithm, made with sience-based papers in mind.
*   **Use Case:** Branded security for DAOs, Institutional Multisigs (Squads), and Consumer Wallets.
*   **Infrastructure:** Native integration with the Squads ecosystem.

## 🛠 Strategic Pivot & Evolution
Hashwall originated as a leading security tool on **TON (Market Breach)**. During our transition to Solana, we identified critical L1-specific infrastructure bottlenecks. Instead of a direct port, we rebuilt the core engine from scratch to be "Solana-Native," focusing on high-speed GPU generation.

**Legacy Proof (TON Development):** [[Link to Old Repo](https://github.com/systemnotmysister/v0-vanity-demo-3d))

## 📁 Repository Structure
*   `/engine`: Preview of the CUDA-based generation logic (Optimized for NVIDIA GPUs).
*   `/app`: Frontend interface for vanity multisig management.
*   `/docs`: Technical architecture and R&D findings.

## ⚖️ Open Source & Proprietary Note
This repository is open-sourced for the Solana Colosseum Hackathon. The high-performance CUDA kernel is partially obfuscated/preview-only to protect Intellectual Property during our ongoing security audit.
