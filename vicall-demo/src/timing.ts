const TOTAL_DURATION_IN_FRAMES = 2250;

const sceneTimingConfig = [
	{
		id: 'scene1',
		script:
			"You've seen AI deepfakes fool millions online. Now the same technology is being used to clone voices and exploit live phone calls.",
		minFrames: 110,
		lingerFrames: 14,
	},
	{
		id: 'scene2',
		script:
			'The rising cost of unprotected communications. Thirteen hundred percent surge in enterprise voice based fraud attacks year over year. Three seconds of audio can seamlessly clone an employee voice. And global AI scam losses are projected to reach forty billion dollars by twenty twenty seven.',
		minFrames: 100,
		lingerFrames: 12,
	},
	{
		id: 'scene3',
		script:
			'Your voice channel has zero protection. Email is protected. Endpoints are protected. Voice calls are not.',
		minFrames: 110,
		lingerFrames: 18,
	},
	{
		id: 'scene4',
		script:
			"That's where Vi Call comes in. Vi Call is a secure calling app deployed by your IT team. Employees install it, place or receive calls, and the app monitors live call audio for synthetic patterns while the conversation happens.",
		minFrames: 150,
		lingerFrames: 26,
	},
	{
		id: 'scene5',
		script:
			'App open. Vi Call shows its own in app call UI while detection runs continuously during the call. The trust signal lives directly on that screen.',
		minFrames: 120,
		lingerFrames: 22,
	},
	{
		id: 'scene6',
		script:
			'App closed. Calls still arrive through normal iPhone CallKit. If the voice sounds safe, the phone stays quiet and the call just keeps going.',
		minFrames: 190,
		lingerFrames: 34,
	},
	{
		id: 'scene7',
		script:
			'If a voice clone is detected, app open turns the in app UI red first. App closed throws a banner notification and vibration on the device.',
		minFrames: 220,
		lingerFrames: 44,
	},
	{
		id: 'scene8',
		script:
			'The detection decision runs on device. Vi Call does not store call recordings, and the alerting path does not rely on cloud inference.',
		minFrames: 120,
		lingerFrames: 18,
	},
	{
		id: 'scene9',
		script:
			'Protection starts at thirty five dollars per seat per month. One dollar and twelve cents per day per employee. Overage is billed at zero point zero one one dollars per minute after four hundred and fifty minutes, through the MSP. One voice clone incident can average five hundred thousand dollars in loss. Talk to your E Safe rep to add Vi Call to your security package.',
		minFrames: 145,
		lingerFrames: 24,
	},
	{
		id: 'scene10',
		script:
			'Available now through E Safe. Powered by Vi Call. Exclusive channel partner, E Safe Partners.',
		minFrames: 80,
		lingerFrames: 34,
	},
] as const;

const estimateSyllables = (input: string): number => {
	const words = input
		.toLowerCase()
		.replace(/vicall/g, 'vi call')
		.match(/[a-z']+/g);

	if (!words) {
		return 1;
	}

	return words.reduce((total, word) => {
		const cleaned = word
			.replace(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, '')
			.replace(/^y/, '');
		const groups = cleaned.match(/[aeiouy]{1,2}/g);
		return total + Math.max(1, groups ? groups.length : 1);
	}, 0);
};

const baseTotal = sceneTimingConfig.reduce(
	(total, scene) => total + scene.minFrames + scene.lingerFrames,
	0
);
const allocatableFrames = TOTAL_DURATION_IN_FRAMES - baseTotal;

const syllableCounts = sceneTimingConfig.map((scene) => estimateSyllables(scene.script));
const syllableTotal = syllableCounts.reduce((total, count) => total + count, 0);

const rawExtras = sceneTimingConfig.map((scene, index) => ({
	id: scene.id,
	value: (allocatableFrames * syllableCounts[index]) / syllableTotal,
}));
const floorExtras = rawExtras.map((entry) => Math.floor(entry.value));
let remainder = allocatableFrames - floorExtras.reduce((total, count) => total + count, 0);

const fractionalOrder = rawExtras
	.map((entry, index) => ({
		index,
		fractional: entry.value - floorExtras[index],
	}))
	.sort((a, b) => b.fractional - a.fractional);

const distributedExtras = [...floorExtras];

for (const entry of fractionalOrder) {
	if (remainder <= 0) {
		break;
	}

	distributedExtras[entry.index] += 1;
	remainder -= 1;
}

export const sceneSchedule = sceneTimingConfig.map((scene, index) => {
	const durationInFrames =
		scene.minFrames + scene.lingerFrames + distributedExtras[index];
	return {
		...scene,
		syllables: syllableCounts[index],
		durationInFrames,
	};
});

export const sceneScheduleWithStarts = sceneSchedule.map((scene, index) => ({
	...scene,
	from:
		index === 0
			? 0
			: sceneSchedule
					.slice(0, index)
					.reduce((total, entry) => total + entry.durationInFrames, 0),
}));

export const sceneById = Object.fromEntries(
	sceneScheduleWithStarts.map((scene) => [scene.id, scene])
) as Record<
	(typeof sceneTimingConfig)[number]['id'],
	(typeof sceneScheduleWithStarts)[number]
>;

export const totalSceneDuration = sceneScheduleWithStarts.reduce(
	(total, scene) => total + scene.durationInFrames,
	0
);
