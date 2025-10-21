# 🏦 KipuBankV2

## Descripción General

**KipuBankV2** es una evolución del contrato original **KipuBank**, diseñado como un **banco descentralizado multi-token** con soporte para Ether nativo y activos ERC-20.  
Integra **control de acceso avanzado**, **contabilidad interna en USD**, **oráculo Chainlink**, y **mecanismos de seguridad robustos** basados en las mejores prácticas de desarrollo en Solidity.

El objetivo de esta versión es simular un contrato inteligente preparado para **entornos de producción**, aplicando estándares de arquitectura, documentación, seguridad y mantenibilidad.

---

## Mejoras Implementadas

### 1. Control de acceso basado en roles
- Implementación mediante `AccessControl` y `Ownable` de OpenZeppelin.  
- Roles definidos:
  - `ADMIN_ROLE`: Configuración global y mantenimiento del sistema.  
  - `MANAGER_ROLE`: Operaciones cotidianas (autorizaciones, desbloqueos, etc.).  
  - `AUDITOR_ROLE`: Acceso de solo lectura para monitoreo.  
- Modificadores `onlyAdmin` y `onlyManager` para restringir funciones críticas.  
- Permite gobernanza distribuida y trazabilidad en auditorías.

### 2. Soporte multi-token
- Admite depósitos y retiros de **Ether nativo (`address(0)`)** y múltiples **tokens ERC-20**.  
- Control mediante `supportedTokens[address] → bool`.  
- Inclusión y remoción de tokens permitidos por administradores.  
- Configuración inicial: ETH, USDC y CE Sepolia.

### 3. Contabilidad interna multi-activo
- Mapeo anidado `balances[user][token]` para rastrear depósitos individuales por token.  
- Variable `totalDepositsUSD` para controlar el límite global del banco (cap).  
- Conversión automática de montos a USD usando un oráculo.

### 4. Límites globales e individuales
- `bankCapUSD`: capacidad total en USD del banco (por defecto 100 000 USD).  
- `withdrawLimitUSD`: límite máximo de retiro por usuario (5 000 USD).  
- Ambos valores son configurables por administradores.

### 5. Integración con Chainlink Data Feeds
- Uso del oráculo **ETH/USD AggregatorV3Interface**.  
- Obtiene precios actualizados con 8 decimales.  
- Conversión automática de montos ETH → USD en `convertToUSD()`.

### 6. Conversión de decimales
- Uso de `IERC20Metadata` para normalizar tokens a una base estándar de **6 decimales (USDC)**.  
- Mecanismo transparente para mantener coherencia contable y evitar errores de precisión.

### 7. Patrones de seguridad y eficiencia
- Patrón **Checks-Effects-Interactions** aplicado en depósitos y retiros.  
- Protección contra reentrancia con `ReentrancyGuard`.  
- Uso de `SafeERC20` para transferencias seguras.  
- Validaciones explícitas con **errores personalizados** (`error Unauthorized()`, `error BankCapExceeded()`, etc.).  
- Variables `constant` e `immutable` (`USD_DECIMALS`, `priceFeed`) para reducir gas y reforzar la inmutabilidad.  
- Funciones auxiliares seguras (`_safeAdd`, `_safeSub`) para prevenir overflow/underflow.

### 8. Mecanismo de pausa y emergencias
- Implementación de `Pausable` para suspensión global del contrato.  
- Funciones `pause()` y `unpause()` disponibles solo para administradores.  
- `emergencyWithdraw()` permite recuperación de fondos cuando el contrato está pausado.

### 9. Funciones `receive()` y `fallback()`
- `receive()` gestiona depósitos directos en ETH, registrándolos automáticamente.  
- `fallback()` bloquea cualquier llamada no reconocida, previniendo ataques o comportamientos inesperados.

---

## Estructura del Contrato

| Sección | Descripción |
|----------|-------------|
| 1. Roles y control de acceso | Definición de roles, modificadores y eventos. |
| 2. Variables globales | Límites, decimales, oráculo y configuraciones. |
| 3. Contabilidad interna | Mapeos `balances`, `supportedTokens` y `totalDepositsUSD`. |
| 4. Eventos | `Deposit`, `Withdraw`, `BankCapUpdated`, etc. |
| 5. Errores personalizados | Validaciones específicas y manejo explícito de fallos. |
| 6. Constructor | Inicialización de roles, límites y tokens soportados. |
| 7. Depósito y retiro | Operaciones principales del sistema bancario. |
| 8. Administración | Gestión del banco y control de tokens permitidos. |
| 9. Oráculo y conversión | Obtención de precios y normalización de valores. |
| 10. Pausable | Control de emergencias del contrato. |
| 11. Funciones auxiliares | Utilidades internas y validaciones seguras. |
| 12. Fallback/Receive | Recepción y control de Ether nativo. |

---

## 🧠 Patrones y Principios Aplicados

- **Checks-Effects-Interactions:** previene vulnerabilidades de reentrancia.  
- **Pull over Push:** los usuarios inician sus propios retiros, evitando transferencias forzadas.  
- **Fail Early, Fail Loud:** revertir ante condiciones inválidas con errores personalizados.  
- **Single Responsibility Principle:** separación clara de responsabilidades (control, lógica y auditoría).  
- **OpenZeppelin Standards:** reutilización de contratos auditados y probados.  
- **Optimización de gas:** uso de `constant`, `immutable` y aritmética segura.

---

## 🧪 Interacción con el Contrato

| Acción                  | Descripción                            | Función                                  |
| ----------------------- | -------------------------------------- | ---------------------------------------- |
| Depositar ETH           | Enviar valor nativo                    | `deposit(address(0), 0)` con `msg.value` |
| Depositar ERC-20        | Transferencia desde `approve()` previo | `deposit(tokenAddress, amount)`          |
| Retirar fondos          | Retiro de saldo del usuario            | `withdraw(tokenAddress, amount)`         |
| Agregar token soportado | Solo admin                             | `addSupportedToken(tokenAddress)`        |
| Actualizar límites      | Cap y retiro individual                | `setBankCap()` / `setWithdrawLimit()`    |
| Consultar precio        | ETH/USD actual                         | `getLatestPrice()`                       |
| Convertir a USD         | Equivalente contable                   | `convertToUSD(token, amount)`            |
| Pausar o reanudar       | Emergencias                            | `pause()` / `unpause()`                  |
| Retiro de emergencia    | Fondos durante pausa                   | `emergencyWithdraw()`                    |


---

## 🧰 Instrucciones de Despliegue

### Remix
1. Abrir [Remix IDE](https://remix.ethereum.org/).  
2. Cargar el archivo `KipuBankV2.sol` dentro del workspace.  
3. En **Solidity Compiler**, seleccionar versión `^0.8.20`.  
4. En **Deploy & Run Transactions**, elegir “Injected Provider – MetaMask”.  
5. Completar los parámetros del constructor:

   ```solidity
   _oracleAddress: Dirección del feed ETH/USD de Chainlink (ej. Sepolia)
   _admin: Dirección del administrador
   _manager: Dirección del manager
   _auditor: Dirección del auditor (opcional)
   _usdc: Dirección del token USDC (ERC-20)
   _cepholia: Dirección del token CE Sepolia o equivalente ERC-20
6. Presionar Deploy y confirmar la transacción en MetaMask.

## 📍 Información de Despliegue

> **Red:** Sepolia Testnet  
> **Dirección del contrato:** [`0x85f53bd850c17B9B6D96A4Aabe9F7EcfA88990c0`](https://sepolia.etherscan.io/address/0x85f53bd850c17B9B6D96A4Aabe9F7EcfA88990c0)  
> **Transacción de despliegue:** [`0x488ebcd3330740591bf32a5d6dcf4dfe167c3f01d47bf33d7478adea77d4ca3f`](https://sepolia.etherscan.io/tx/0x488ebcd3330740591bf32a5d6dcf4dfe167c3f01d47bf33d7478adea77d4ca3f)  
> **Código verificado:** [Sourcify Repository](https://repo.sourcify.dev/11155111/0x85f53bd850c17B9B6D96A4Aabe9F7EcfA88990c0/)  
