'use strict';
const fs = require('fs');
const path = require('path');

// Tareas programadas tipo cron (pedido del usuario, 2026-07-14): "todos los lunes a las 8am
// resumime el vault". Sin librerías nuevas de cron -- 3 tipos simples cubren el caso real de un
// asistente personal: diaria, semanal (día de semana + hora), o cada N horas.

function schedulePath(mentisEnvDir) {
  return path.join(mentisEnvDir, 'scheduled-tasks.json');
}

function loadTasks(mentisEnvDir) {
  try {
    return JSON.parse(fs.readFileSync(schedulePath(mentisEnvDir), 'utf-8'));
  } catch {
    return [];
  }
}

function saveTasks(mentisEnvDir, tasks) {
  fs.writeFileSync(schedulePath(mentisEnvDir), JSON.stringify(tasks, null, 2), 'utf-8');
}

function newTaskId() {
  return `task-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function validateSchedule(schedule) {
  if (!schedule || typeof schedule !== 'object') throw new Error('falta "schedule"');
  if (schedule.type === 'daily') {
    if (!Number.isInteger(schedule.hour) || schedule.hour < 0 || schedule.hour > 23) throw new Error('hora inválida');
    if (!Number.isInteger(schedule.minute) || schedule.minute < 0 || schedule.minute > 59) throw new Error('minuto inválido');
  } else if (schedule.type === 'weekly') {
    if (!Number.isInteger(schedule.dayOfWeek) || schedule.dayOfWeek < 0 || schedule.dayOfWeek > 6) throw new Error('día de la semana inválido');
    if (!Number.isInteger(schedule.hour) || schedule.hour < 0 || schedule.hour > 23) throw new Error('hora inválida');
    if (!Number.isInteger(schedule.minute) || schedule.minute < 0 || schedule.minute > 59) throw new Error('minuto inválido');
  } else if (schedule.type === 'interval') {
    if (!Number.isFinite(schedule.everyMinutes) || schedule.everyMinutes < 5) throw new Error('el intervalo mínimo es 5 minutos');
  } else {
    throw new Error(`tipo de schedule desconocido: ${schedule.type}`);
  }
}

function createTask(mentisEnvDir, { name, prompt, schedule }) {
  if (!name || !name.trim()) throw new Error('falta el nombre de la tarea');
  if (!prompt || !prompt.trim()) throw new Error('falta el prompt de la tarea');
  validateSchedule(schedule);
  const tasks = loadTasks(mentisEnvDir);
  const task = {
    id: newTaskId(), name: name.trim(), prompt: prompt.trim(), schedule,
    enabled: true, conversationId: null, lastRunAt: null, lastResult: null
  };
  tasks.push(task);
  saveTasks(mentisEnvDir, tasks);
  return task;
}

function updateTask(mentisEnvDir, id, patch) {
  const tasks = loadTasks(mentisEnvDir);
  const idx = tasks.findIndex((t) => t.id === id);
  if (idx === -1) throw new Error(`tarea no encontrada: ${id}`);
  if (patch.schedule) validateSchedule(patch.schedule);
  tasks[idx] = {...tasks[idx],...patch };
  saveTasks(mentisEnvDir, tasks);
  return tasks[idx];
}

function deleteTask(mentisEnvDir, id) {
  const tasks = loadTasks(mentisEnvDir).filter((t) => t.id !== id);
  saveTasks(mentisEnvDir, tasks);
}

// Misma clave de "dia" que ya usa stats-store.js: YYYY-MM-DD, pero en horario LOCAL (no UTC) --
// a diferencia de las estadísticas (donde UTC alcanza para contar actividad), acá "todos los
// lunes a las 8am" tiene que ser las 8am del usuario, no las 8am UTC.
function localDateKey(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function isDue(task, now) {
  if (!task.enabled) return false;
  const { schedule } = task;
  const lastRun = task.lastRunAt ? new Date(task.lastRunAt) : null;

  if (schedule.type === 'interval') {
    if (!lastRun) return true;
    return now.getTime() - lastRun.getTime() >= schedule.everyMinutes * 60000;
  }

  const hourMinuteMatches = now.getHours() === schedule.hour && now.getMinutes() === schedule.minute;
  if (!hourMinuteMatches) return false;
  if (schedule.type === 'weekly' && now.getDay() !== schedule.dayOfWeek) return false;
  // Ya corrio hoy (mismo dia local) -- no disparar de nuevo aunque el tick vuelva a caer en el
  // mismo minuto por drift del timer.
  if (lastRun && localDateKey(lastRun) === localDateKey(now)) return false;
  return true;
}

function computeDueTasks(tasks, now) {
  return tasks.filter((t) => isDue(t, now));
}

const DAY_LABELS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];

function describeSchedule(schedule) {
  const hhmm = (h, m) => `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  if (schedule.type === 'daily') return `Todos los días a las ${hhmm(schedule.hour, schedule.minute)}`;
  if (schedule.type === 'weekly') return `Todos los ${DAY_LABELS[schedule.dayOfWeek]} a las ${hhmm(schedule.hour, schedule.minute)}`;
  if (schedule.type === 'interval') return `Cada ${schedule.everyMinutes} minutos`;
  return 'Programación desconocida';
}

module.exports = { loadTasks, saveTasks, createTask, updateTask, deleteTask, computeDueTasks, isDue, describeSchedule, validateSchedule };
