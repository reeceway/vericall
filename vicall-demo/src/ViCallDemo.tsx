import React from 'react';
import {AbsoluteFill, Audio, Sequence, interpolate} from 'remotion';
import {ChannelVariant} from './channelCopy';
import {Scene1Hook} from './scenes/Scene1Hook';
import {Scene2Stats} from './scenes/Scene2Stats';
import {Scene3Gap} from './scenes/Scene3Gap';
import {Scene4WhatIsVicall} from './scenes/Scene4WhatIsVicall';
import {Scene5MakeCall} from './scenes/Scene5MakeCall';
import {Scene6VerifiedJourney} from './scenes/Scene6VerifiedJourney';
import {Scene7CloneJourney} from './scenes/Scene7CloneJourney';
import {Scene8Privacy} from './scenes/Scene8Privacy';
import {Scene9Cost} from './scenes/Scene9Cost';
import {Scene10Close} from './scenes/Scene10Close';
import {hasStaticAsset, staticAsset} from './lib/static';
import {sceneById} from './timing';

const musicVolume = (frame: number): number => {
	const cloneStart = sceneById.scene7.from;
	const privacyStart = sceneById.scene8.from;
	const closeStart = sceneById.scene10.from;
	const cloneSilenceStart = cloneStart + Math.round(sceneById.scene7.durationInFrames * 0.66);

	if (frame < cloneStart) return 0.12;
	if (frame < cloneStart + 10)
		return interpolate(frame, [cloneStart, cloneStart + 10], [0.12, 0.25], {
			extrapolateLeft: 'clamp',
			extrapolateRight: 'clamp',
		});
	if (frame < cloneStart + 54) return 0.25;
	if (frame < cloneStart + 72)
		return interpolate(frame, [cloneStart + 54, cloneStart + 72], [0.25, 0.12], {
			extrapolateLeft: 'clamp',
			extrapolateRight: 'clamp',
		});
	if (frame < cloneSilenceStart) return 0.12;
	if (frame < privacyStart) return 0.06;
	if (frame < closeStart) return 0.12;
	return interpolate(frame, [closeStart, closeStart + sceneById.scene10.durationInFrames], [0.12, 0], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp',
	});
};

const OptionalAudio: React.FC<{path: string; volume: number | ((frame: number) => number)}> = ({path, volume}) => {
	const asset = staticAsset(path);
	if (!asset || !hasStaticAsset(path)) return null;
	return <Audio src={asset} volume={volume} />;
};

export const ViCallDemo: React.FC<{channelVariant?: ChannelVariant}> = ({
	channelVariant = 'esafe',
}) => {
	return (
		<AbsoluteFill>
			<Sequence from={sceneById.scene1.from} durationInFrames={sceneById.scene1.durationInFrames}>
				<Scene1Hook durationInFrames={sceneById.scene1.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene2.from} durationInFrames={sceneById.scene2.durationInFrames}>
				<Scene2Stats durationInFrames={sceneById.scene2.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene3.from} durationInFrames={sceneById.scene3.durationInFrames}>
				<Scene3Gap durationInFrames={sceneById.scene3.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene4.from} durationInFrames={sceneById.scene4.durationInFrames}>
				<Scene4WhatIsVicall durationInFrames={sceneById.scene4.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene5.from} durationInFrames={sceneById.scene5.durationInFrames}>
				<Scene5MakeCall durationInFrames={sceneById.scene5.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene6.from} durationInFrames={sceneById.scene6.durationInFrames}>
				<Scene6VerifiedJourney durationInFrames={sceneById.scene6.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene7.from} durationInFrames={sceneById.scene7.durationInFrames}>
				<Scene7CloneJourney durationInFrames={sceneById.scene7.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene8.from} durationInFrames={sceneById.scene8.durationInFrames}>
				<Scene8Privacy durationInFrames={sceneById.scene8.durationInFrames} />
			</Sequence>
			<Sequence from={sceneById.scene9.from} durationInFrames={sceneById.scene9.durationInFrames}>
				<Scene9Cost
					durationInFrames={sceneById.scene9.durationInFrames}
					channelVariant={channelVariant}
				/>
			</Sequence>
			<Sequence from={sceneById.scene10.from} durationInFrames={sceneById.scene10.durationInFrames}>
				<Scene10Close
					durationInFrames={sceneById.scene10.durationInFrames}
					channelVariant={channelVariant}
				/>
			</Sequence>

			<OptionalAudio path="voiceover.mp3" volume={1} />
			<OptionalAudio path="music.mp3" volume={(f) => musicVolume(f)} />
			<Sequence from={sceneById.scene7.from} durationInFrames={6}>
				<OptionalAudio path="impact.mp3" volume={0.5} />
			</Sequence>
		</AbsoluteFill>
	);
};
